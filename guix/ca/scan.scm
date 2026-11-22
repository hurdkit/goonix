;;; goonix: read-only measurements of store self references.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 7778777 <7778777@7778777.online>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.

(define-module (guix ca scan)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:use-module (srfi srfi-14)
  #:use-module (srfi srfi-34)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 iconv)
  #:use-module (rnrs bytevectors)
  #:use-module ((guix store) #:select (%store-prefix))
  #:autoload (zlib) (make-gzip-input-port make-zlib-input-port)
  #:autoload (lzma) (make-xz-input-port)
  #:export (<scan-report>
            scan-report?
            scan-report-item
            scan-report-files
            scan-report-bytes
            scan-report-full
            scan-report-fragments
            scan-report-utf16
            scan-report-hidden
            scan-report-names
            scan-report-links
            scan-report-undecodable
            scan-report-unsupported
            scan-report->alist
            scan-store-item
            store-directory-items))

(define-record-type <scan-report>
  (make-scan-report item files bytes full fragments utf16 hidden names links
                    undecodable unsupported)
  scan-report?
  (item scan-report-item)
  (files scan-report-files)
  (bytes scan-report-bytes)
  (full scan-report-full)
  (fragments scan-report-fragments)
  (utf16 scan-report-utf16)
  (hidden scan-report-hidden)
  (names scan-report-names)
  (links scan-report-links)
  (undecodable scan-report-undecodable)
  (unsupported scan-report-unsupported))

(define (scan-report->alist report)
  "Return REPORT as an alist suitable for JSON serialization."
  (list (cons "item" (scan-report-item report))
        (cons "files" (scan-report-files report))
        (cons "bytes" (scan-report-bytes report))
        (cons "full" (scan-report-full report))
        (cons "frag" (scan-report-fragments report))
        (cons "utf16" (scan-report-utf16 report))
        (cons "hidden" (scan-report-hidden report))
        (cons "names" (scan-report-names report))
        (cons "links" (scan-report-links report))
        (cons "undecodable" (scan-report-undecodable report))
        (cons "unsupported" (scan-report-unsupported report))))

(define (substring-bytes bytes start length)
  (let ((result (make-bytevector length)))
    (bytevector-copy! bytes start result 0 length)
    result))

(define (utf16-le-bytes hash)
  "Return the 32 ASCII characters of HASH in UTF-16LE, without a BOM."
  (let ((result (make-bytevector 64)))
    (let loop ((index 0))
      (if (= index 32)
          result
          (begin
            (bytevector-u8-set! result (* index 2)
                                (bytevector-u8-ref hash index))
            (loop (+ index 1)))))))

(define (latin1 bytes)
  (bytevector->string bytes "ISO-8859-1"))

(define (append-bytes first second)
  "Return a bytevector holding FIRST followed by SECOND."
  (let* ((size (bytevector-length first))
         (result (make-bytevector (+ size (bytevector-length second)))))
    (bytevector-copy! first 0 result 0 size)
    (bytevector-copy! second 0 result size (bytevector-length second))
    result))

(define (add-counts totals counts)
  "Return the alist TOTALS with the numbers of the alist COUNTS added."
  (fold (lambda (entry totals)
          (let ((old (or (assq-ref totals (car entry)) 0)))
            (alist-cons (car entry) (+ old (cdr entry))
                        (alist-delete (car entry) totals eq?))))
        totals
        counts))

(define (occurrence-ends text needle)
  "Return the offset just past each occurrence of NEEDLE in TEXT."
  (let ((size (string-length needle)))
    (let loop ((start 0) (ends '()))
      (let ((at (string-contains text needle start)))
        (if at
            (loop (+ at 1) (cons (+ at size) ends))
            ends)))))

(define (whole-hash-at? text hash-text start)
  "Return true if HASH-TEXT lies at offset START of TEXT."
  (and (>= start 0)
       (<= (+ start 32) (string-length text))
       (string-prefix? hash-text text 0 32 start (+ start 32))))

;; An 8-character window of the hash is a fragment unless the whole hash
;; lies around it.  Deciding that takes up to this many bytes after the
;; window.
(define %right-context 24)

;; Bytes kept from one read to the next: the longest needle (the hash in
;; UTF-16LE), the right context, and the left context of a window.
(define %retained 127)

(define (scan-bytes/sweeps hash bytes from to)
  "The straightforward reading of the self-reference rules: one
'string-contains' sweep per needle — the whole hash, its 25 eight-character
windows and its UTF-16LE encoding.  Kept as the reference the single-pass
scanner below is measured against (tests/ca-scan.scm); it is 27 passes over
every chunk, which is what made a full closure scan slow."
  (define text (latin1 bytes))
  (define hash-text (latin1 hash))
  (define (owned needle)
    (filter (lambda (end) (and (> end from) (<= end to)))
            (occurrence-ends text needle)))
  (define (fragments offset)
    (count (lambda (end)
             (not (whole-hash-at? text hash-text (- end 8 offset))))
           (owned (substring hash-text offset (+ offset 8)))))
  (list (cons 'full (length (owned hash-text)))
        (cons 'fragments (apply + (map fragments (iota 25))))
        (cons 'utf16 (length (owned (latin1 (utf16-le-bytes hash)))))))

;; The hash's 8-byte windows, keyed by the window's bytes as an exact
;; integer.  A window of the content can only be one of the hash's windows if
;; it is in this table, so the table answers "which offsets does this window
;; match" without a search per offset.  A hash with repeated windows maps one
;; key to several offsets and each counts, as the per-offset sweeps counted
;; each.
(define (window-value bytes start)
  "The 8 bytes at START of BYTES as an exact integer, most significant first.
A fixnum on a 64-bit Guile, so the table lookup stays out of the bignum
path."
  (let loop ((index 0) (key 0))
    (if (= index 8)
        key
        (loop (+ index 1)
              (logior (ash key 8)
                      (bytevector-u8-ref bytes (+ start index)))))))

(define (hash-window-table hash)
  (let ((table (make-hash-table 32)))
    (let loop ((offset 0))
      (when (<= offset 24)
        (let ((key (window-value hash offset)))
          (hashv-set! table key (cons offset (hashv-ref table key '()))))
        (loop (+ offset 1))))
    table))

(define (bytes-equal? bytes start needle)
  "Whether the (length NEEDLE) bytes at START of BYTES are NEEDLE.  False
when they would run past either end, as the string comparison was."
  (let ((size (bytevector-length needle)))
    (and (>= start 0)
         (<= (+ start size) (bytevector-length bytes))
         (let loop ((index 0))
           (or (= index size)
               (and (= (bytevector-u8-ref bytes (+ start index))
                       (bytevector-u8-ref needle index))
                    (loop (+ index 1))))))))

(define (window-anchor-set hash-text)
  "A set of characters that every 8-character window of HASH-TEXT contains at
least one of.  A search of the content for that SET therefore finds every
place a window of the hash can end, in one C pass, and the set is kept small
so that pass has few hits.

Greedy: the window with the fewest candidate characters left is covered
first, by its rarest character in the hash.  A character covers the windows
it lies in, so 4 characters always suffice (windows 0..7, 8..15, 16..23,
24..31 partition the hash) and a repeated-character hash needs fewer.  The
choice cannot change the result: it only decides which positions are
examined, and every window is examined at least once."
  (let ((positions (make-vector 256 '()))
        (covered (make-vector 25 #f)))
    (let loop ((index 0))
      (when (< index 32)
        (let ((byte (char->integer (string-ref hash-text index))))
          (vector-set! positions byte (cons index (vector-ref positions byte))))
        (loop (+ index 1))))
    (let pick ((chosen '()))
      (let ((open (filter (lambda (offset) (not (vector-ref covered offset)))
                          (iota 25))))
        (if (null? open)
            (list->char-set (map integer->char chosen))
            ;; The rarest character among those lying in an uncovered window,
            ;; preferring one that covers the most uncovered windows.
            (let loop ((byte 0) (best #f) (best-score #f))
              (if (= byte 256)
                  (let ((covers (filter (lambda (offset)
                                          (any (lambda (at)
                                                 (and (<= offset at)
                                                      (< at (+ offset 8))))
                                               (vector-ref positions best)))
                                        open)))
                    (for-each (lambda (offset) (vector-set! covered offset #t))
                              covers)
                    (pick (cons best chosen)))
                  (let* ((at (vector-ref positions byte))
                         (hits (count (lambda (offset)
                                        (any (lambda (position)
                                               (and (<= offset position)
                                                    (< position (+ offset 8))))
                                             at))
                                      open))
                         ;; More uncovered windows first, then rarer in the
                         ;; hash (fewer occurrences means fewer hits).
                         (score (and (> hits 0) (cons hits (- (length at))))))
                    (if (and score
                             (or (not best-score)
                                 (> (car score) (car best-score))
                                 (and (= (car score) (car best-score))
                                      (> (cdr score) (cdr best-score)))))
                        (loop (+ byte 1) byte score)
                        (loop (+ byte 1) best best-score))))))))))

(define* (scan-bytes hash bytes
                     #:optional (from 0) (to (bytevector-length bytes)))
  "Count the self references in BYTES that end after offset FROM and not
after offset TO.  Return an alist with the keys full, fragments and utf16.
Every occurrence counts, also one that overlaps the one before.

One pass over the content, not one 'string-contains' sweep per needle.  The
pass is a search for a SINGLE character of the hash, done by 'string-index'
in C; every 8-byte window of the hash contains that character or another, so
each window that ends in the content ends at or before one of those hits.
At a hit the at most 25 windows covering it are looked up in the hash's
window table by their bytes, and each match is settled by comparing the
whole hash once at the alignment that would cover it — the comparison the
per-offset sweep made after searching the whole text for the window.  It
reads the bytes AROUND the window, which is why a chunk leaves
%RIGHT-CONTEXT bytes undecided: the covering hash may end up to 24 bytes
later.

The whole hash and its UTF-16LE encoding are found by their own C searches,
one each, instead of being recounted per window."
  (let* ((size (bytevector-length bytes))
         (text (latin1 bytes))
         (hash-text (latin1 hash))
         (windows (hash-window-table hash))
         (utf16 (utf16-le-bytes hash))
         (anchor (window-anchor-set hash-text))
         (full 0) (fragments 0) (utf16-count 0))
    (define (owned? end) (and (> end from) (<= end to)))
    ;; Whole hashes: one C search, every occurrence, overlapping included.
    (let loop ((start 0))
      (let ((at (string-contains text hash-text start)))
        (when at
          (when (owned? (+ at 32)) (set! full (+ full 1)))
          (loop (+ at 1)))))
    ;; The hash in UTF-16LE: one C search over the same text.
    (let ((needle (latin1 utf16)))
      (let loop ((start 0))
        (let ((at (string-contains text needle start)))
          (when at
            (when (owned? (+ at 64)) (set! utf16-count (+ utf16-count 1)))
            (loop (+ at 1))))))
    ;; Fragments: walk the hits of the anchor set.  A window ending at END
    ;; that matches the hash contains an anchor character, so END is within 8
    ;; of a hit.  Hits come in increasing order, so the candidate ends of a
    ;; hit overlap only those of the previous few hits: remembering the
    ;; highest end already examined is enough to examine each end once, with
    ;; no per-byte table.  The window's LAST byte must be the last byte of one
    ;; of the hash's windows, which one vector reference decides; only then
    ;; are the window's 8 bytes read and compared.  In a binary almost every
    ;; candidate is rejected by that one reference.
    (let ((by-last (make-vector 256 '()))
          (by-first (make-vector 256 #f)))
      ;; Bucket the hash's windows by their last byte, and note which first
      ;; bytes any window starts with: two vector references reject almost
      ;; every candidate before its 8 bytes are read.
      (let loop ((offset 0))
        (when (<= offset 24)
          (let ((last (bytevector-u8-ref hash (+ offset 7))))
            (vector-set! by-last last
                         (cons (cons (window-value hash offset) offset)
                               (vector-ref by-last last)))
            (vector-set! by-first (bytevector-u8-ref hash offset) #t))
          (loop (+ offset 1))))
      (let hit-loop ((hit (string-index text anchor 0)) (done 7))
        (when hit
          (let end-loop ((end (max (+ hit 1) (+ done 1)))
                         (stop (min (+ hit 8) size)))
            (when (<= end stop)
              (let ((candidates (vector-ref by-last
                                            (bytevector-u8-ref bytes (- end 1)))))
                (when (and (pair? candidates)
                           (vector-ref by-first
                                       (bytevector-u8-ref bytes (- end 8)))
                           (owned? end))
                  (let ((key (window-value bytes (- end 8)))
                        (window-start (- end 8)))
                    (let try ((rest candidates))
                      (when (pair? rest)
                        (let ((candidate (car rest)))
                          (when (= (car candidate) key)
                            (unless (bytes-equal? bytes
                                                  (- window-start (cdr candidate))
                                                  hash)
                              (set! fragments (+ fragments 1)))))
                        (try (cdr rest)))))))
              (end-loop (+ end 1) stop)))
          (hit-loop (string-index text anchor (+ hit 1))
                    (max done (min (+ hit 8) size))))))
    (list (cons 'full full)
          (cons 'fragments fragments)
          (cons 'utf16 utf16-count))))

(define* (scan-port hash port limit #:key (chunk-size (* 128 1024))
                    (count-bytes? #f))
  "Read at most LIMIT bytes from PORT, CHUNK-SIZE at a time, and return what
'scan-bytes' returns for all of them at once.

Each round scans the retained bytes followed by the new ones.  A round that
is not the last one leaves the occurrences that end in its last
%RIGHT-CONTEXT bytes to the next round, which has the bytes after them;
DECIDED is the offset up to which occurrences are already counted."
  (let loop ((retained #vu8()) (decided 0) (remaining limit) (totals '()))
    (let* ((wanted (min chunk-size remaining))
           (chunk (if (zero? wanted)
                      (eof-object)
                      (get-bytevector-n port wanted)))
           (last? (eof-object? chunk))
           (bytes (if last? retained (append-bytes retained chunk)))
           (size (bytevector-length bytes))
           (to (if last? size (max decided (- size %right-context))))
           (totals (add-counts totals (scan-bytes hash bytes decided to))))
      (if last?
          (if count-bytes?
              (add-counts totals (list (cons 'decoded-bytes (- limit remaining))))
              totals)
          (let ((keep (min size %retained)))
            (loop (substring-bytes bytes (- size keep) keep)
                  (- to (- size keep))
                  (- remaining (bytevector-length chunk))
                  totals))))))

(define (compressed-kind file)
  (cond ((string-suffix? ".gz" file) 'gzip)
        ((string-suffix? ".xz" file) 'xz)
        ((string-suffix? ".lzma" file) 'unsupported-lzma)
        ((string-suffix? ".bz2" file) 'unsupported-bzip2)
        ((any (lambda (suffix) (string-suffix? suffix file))
              '(".zip" ".jar" ".whl" ".egg" ".war" ".apk" ".epub" ".odt"))
         'unsupported-zip)
        (else #f)))

(define (drain-byte-count port)
  "Read PORT to EOF and return its byte count."
  (let loop ((count 0))
    (let ((chunk (get-bytevector-n port (* 128 1024))))
      (if (eof-object? chunk)
          count
          (loop (+ count (bytevector-length chunk)))))))

(define (open-decoder file kind)
  "Open FILE's decoder after resolving its module; installation errors escape."
  (resolve-interface (case kind ((gzip) '(zlib)) ((xz) '(lzma))))
  (let ((port (open-file file "r0")))
    (case kind
      ((gzip) (make-zlib-input-port port #:format 'gzip))
      ((xz) (make-xz-input-port port #:close? #t)))))

(define (scan-decoded hash input limit)
  "Scan INPUT and report whether decompression exceeded LIMIT."
  (let* ((counts (scan-port hash input limit #:count-bytes? #t))
         (extra (get-bytevector-n input 1)))
    (append (list (cons 'hidden (or (assq-ref counts 'full) 0)))
            (if (eof-object? extra) '() '((unsupported . 1)))
            (list (cons 'decoded-bytes
                        (+ (or (assq-ref counts 'decoded-bytes) 0)
                           (if (eof-object? extra) 0 1)))))))

(define (scan-gzip hash file limit)
  "Scan one gzip member strictly and reject unexamined additional members."
  (let ((input (open-decoder file 'gzip)))
    (dynamic-wind
      (const #f)
      (lambda ()
        (catch 'zlib-error
          (lambda () (scan-decoded hash input limit))
          (lambda _ '((undecodable . 1)))))
      (lambda () (close-port input)))))

(define (gzip-all-byte-count file)
  "Return the total decompressed size using the multi-member gzip reader."
  (let* ((port (open-file file "r0"))
         (input (make-gzip-input-port port)))
    (let ((count (drain-byte-count input)))
      (close-port input)
      count)))

(define (gzip-trailer-size file)
  "Return the size field that ends FILE, read as the last four bytes of a
gzip member's trailer, or #f when FILE is shorter than that."
  (let ((size (stat:size (stat file))))
    (and (>= size 4)
         (call-with-input-file file
           (lambda (port)
             (seek port (- size 4) SEEK_SET)
             (bytevector-u32-ref (get-bytevector-n port 4) 0 (endianness little)))
           #:binary #t))))

(define (scan-gzip-file hash file limit)
  "Scan FILE's first gzip member.  The result has 'undecodable' when that
member is damaged, and 'unsupported' when the limit was reached or FILE holds
anything besides the member that was scanned."
  (let* ((result (scan-gzip hash file limit))
         (decoded (or (assq-ref result 'decoded-bytes) 0))
         (public (alist-delete 'decoded-bytes result eq?)))
    (cond ((assq-ref result 'undecodable) public)
          ((assq-ref result 'unsupported) public)
          ((and (eqv? (gzip-trailer-size file) (modulo decoded (expt 2 32)))
                (= decoded (gzip-all-byte-count file)))
           public)
          (else (append public '((unsupported . 1)))))))

(define* (scan-compressed hash file #:optional (limit (* 64 1024 1024)))
  "Return hidden self references, or a decoder/limit coverage counter."
  (let ((kind (compressed-kind file)))
    (cond ((or (not kind) (zero? (stat:size (stat file)))) '())
          ((eq? kind 'gzip) (scan-gzip-file hash file limit))
          ((eq? kind 'xz)
           (let ((input (open-decoder file 'xz)))
             (dynamic-wind
               (const #f)
               (lambda ()
                 (guard (condition
                         (((module-ref (resolve-interface '(lzma))
                                       'lzma-error?) condition)
                          '((undecodable . 1))))
                   (alist-delete 'decoded-bytes
                                 (scan-decoded hash input limit) eq?)))
               (lambda () (close-port input)))))
          (else '((unsupported . 1))))))

(define (store-directory-items directory)
  "Return sorted directory store items below DIRECTORY, without following links."
  (sort (filter-map
         (lambda (name)
           (let ((path (string-append directory "/" name)))
             (and (> (string-length name) 33)
                  (char=? #\- (string-ref name 32))
                  (eq? 'directory (stat:type (lstat path)))
                  name)))
         (scandir directory))
        string<?))

(define (file-count entry)
  "Normalize a regular file's UTF-16 occurrence count to a presence count."
  (if (and (eq? (car entry) 'utf16) (> (cdr entry) 0))
      (cons 'utf16 1)
      entry))

(define (scan-store-item item)
  "Read ITEM's tree and return its self-reference report.  ITEM is a store
item name or a full path; no file is modified and no symlink is followed."
  (let* ((path (if (string-prefix? "/" item)
                   item (string-append (%store-prefix) "/" item)))
         (name (basename path))
         (hash (string->utf8 (string-take name 32)))
         (counters (make-vector 10 0))
         (keys '(files bytes full fragments utf16 hidden names links
                 undecodable unsupported)))
    (define (add! key amount)
      (let ((index (list-index (lambda (candidate) (eq? key candidate)) keys)))
        (vector-set! counters index (+ amount (vector-ref counters index)))))
    (define (add-file-counts! counts)
      (for-each (lambda (entry)
                  (add! (car entry) (cdr entry)))
                (map file-count counts)))
    (define (visit path depth)
      (let ((stat (lstat path)))
        (when (and (> depth 0)
                   (string-contains (basename path) (utf8->string hash)))
          (add! 'names 1))
        (case (stat:type stat)
          ((regular)
           (unless (zero? (stat:size stat))
             (add! 'files 1))
           (add! 'bytes (stat:size stat))
           (let ((file-port (open-file path "r0")))
             (dynamic-wind
               (const #f)
               (lambda ()
                 (add-file-counts!
                  (scan-port hash file-port (stat:size stat))))
               (lambda () (close-port file-port))))
           (for-each (lambda (entry) (add! (car entry) (cdr entry)))
                     (scan-compressed hash path)))
          ((symlink)
           (when (string-contains (readlink path) (utf8->string hash))
             (add! 'links 1)))
          ((directory)
           (for-each (lambda (entry)
                       (visit (string-append path "/" entry) (+ depth 1)))
                     (sort (scandir path
                                    (lambda (entry)
                                      (not (member entry '("." "..")))))
                           string<?))))))
    (visit path 0)
    (apply make-scan-report name (vector->list counters))))

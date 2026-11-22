;;; goonix: the single-pass self-reference scanner against the sweep scanner.
;;;
;;; scan-bytes used to run one 'string-contains' sweep per needle: the whole
;;; hash, its 25 eight-byte windows and its UTF-16LE encoding, 27 passes over
;;; every chunk.  It now makes one pass.  The counts must not change, so this
;;; test runs BOTH over the same inputs and requires identical results —
;;; every kind, at every chunk size, on the CA fixtures, on randomised
;;; payloads that place references at and across chunk boundaries, and on
;;; real store items when they are available.
(use-modules (guix ca scan)
             (guix tests)
             (guix store)
             (ice-9 binary-ports)
             (ice-9 ftw)
             (ice-9 match)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-64))

(define sweeps (@@ (guix ca scan) scan-bytes/sweeps))
(define one-pass (@@ (guix ca scan) scan-bytes))
(define scan-port* (@@ (guix ca scan) scan-port))
(define %retained (@@ (guix ca scan) %retained))
(define %right-context (@@ (guix ca scan) %right-context))

(define (sorted counts)
  (sort counts (lambda (a b) (string<? (symbol->string (car a))
                                       (symbol->string (car b))))))

;; The hash the CA fixtures use, and a second one with a repeated 8-byte
;; window: one key then maps to several offsets, and each must still count.
(define %hash "0123456789abcdfghijklmnpqrsvwxyz")
(define %repeat-hash "abababababababababababababababab")

(define (utf16-le hash)
  (string->utf16 hash (endianness little)))

(define (bytes . parts)
  (u8-list->bytevector
   (append-map (lambda (part)
                 (cond ((bytevector? part) (bytevector->u8-list part))
                       ((string? part) (bytevector->u8-list (string->utf8 part)))
                       ((list? part)
                        (append-map (lambda (piece)
                                      (cond ((string? piece)
                                             (bytevector->u8-list
                                              (string->utf8 piece)))
                                            ((bytevector? piece)
                                             (bytevector->u8-list piece))
                                            (else (list piece))))
                                    part))
                       (else (list part))))
               parts)))

(test-begin "ca-scan")

(test-group "the two scanners agree on the fixture payloads"
  (for-each
   (lambda (hash)
     (let ((h (string->utf8 hash)))
       (for-each
        (match-lambda
          ((label . payload)
           (test-equal (string-append label " (" hash ")")
             (sorted (sweeps h payload 0 (bytevector-length payload)))
             (sorted (one-pass h payload)))))
        `(("empty" . #vu8())
          ("no reference" . ,(bytes "nothing to see here" (make-list 64 90)))
          ("whole hash" . ,(bytes h))
          ("whole hash twice" . ,(bytes h 7 h))
          ("overlapping whole hashes" . ,(bytes h (substring hash 1 32)))
          ("every 8-byte window" .
           ,(bytes (append-map (lambda (offset)
                                 (list (substring hash offset (+ offset 8)) 0))
                               (iota 25))))
          ("windows back to back" .
           ,(bytes (append-map (lambda (offset)
                                 (list (substring hash offset (+ offset 8))))
                               (iota 25))))
          ("utf16" . ,(bytes (utf16-le hash)))
          ("utf16 twice" . ,(bytes (utf16-le hash) 0 (utf16-le hash)))
          ("mixed kinds" .
           ,(bytes 3 0 255 h 7 (substring hash 3 15) 11 (utf16-le hash) 13
                   h (substring hash 20 28) 17 (make-list 201 90)))
          ("hash among arbitrary bytes" .
           ,(bytes 0 255 65 0 h 0 128 66))
          ("truncated hash at the end" . ,(bytes (make-list 40 65) (substring hash 0 31)))
          ("truncated hash at the start" . ,(bytes (substring hash 1 32) (make-list 40 66)))
          ("all byte values" . ,(u8-list->bytevector (iota 256)))
          ("zero run" . ,(bytes (make-list 128 0)))
          ("hash byte run" . ,(bytes (make-list 128 (char->integer #\a))))))))
   (list %hash %repeat-hash)))

(test-group "the two scanners agree on randomised payloads"
  ;; Deterministic: the same seed builds the same payloads on every run.
  (define state (seed->random-state 20261121))
  (define (random-bytes size)
    (let ((result (make-bytevector size)))
      (let loop ((index 0))
        (when (< index size)
          (bytevector-u8-set! result index (random 256 state))
          (loop (+ index 1))))
      result))
  (for-each
   (lambda (hash)
     (let ((h (string->utf8 hash)))
       (let loop ((round 0))
         (when (< round 60)
           (let* ((pieces
                   (map (lambda (_)
                          (case (random 6 state)
                            ((0) (random-bytes (random 40 state)))
                            ((1) h)
                            ((2) (string->utf8
                                  (let ((offset (random 25 state)))
                                    (substring hash offset (+ offset 8)))))
                            ((3) (utf16-le hash))
                            ((4) (random-bytes 1))
                            (else (string->utf8
                                   (substring hash 0 (+ 1 (random 32 state)))))))
                        (iota (+ 1 (random 8 state)))))
                  (payload (apply bytes pieces))
                  (size (bytevector-length payload)))
             ;; Whole-content agreement.
             (test-equal (format #f "random payload ~a (~a)" round hash)
               (sorted (sweeps h payload 0 size))
               (sorted (one-pass h payload)))
             ;; Agreement on an arbitrary owned range, which is what the
             ;; chunked reader asks for.
             (let ((from (random (+ size 1) state)))
               (let ((to (+ from (random (+ (- size from) 1) state))))
                 (test-equal (format #f "random range ~a [~a,~a] (~a)"
                                     round from to hash)
                   (sorted (sweeps h payload from to))
                   (sorted (one-pass h payload from to)))))
             (loop (+ round 1)))))))
   (list %hash %repeat-hash)))

(test-group "chunked reads agree with the whole-content scan"
  ;; The boundary rule: an occurrence that straddles two chunks must still be
  ;; found, and none may be counted twice.  Every small chunk size is tried,
  ;; as tests/ca.scm does, plus sizes around the retained window.
  (for-each
   (lambda (hash)
     (let* ((h (string->utf8 hash))
            (payload (bytes 3 0 255 h 7 (substring hash 3 15) 11
                            (utf16-le hash) 13 h (substring hash 20 28) 17
                            (make-list 201 90)))
            (expected (sorted (one-pass h payload))))
       (test-equal (string-append "every chunk size 1..400 (" hash ")")
         '()
         (filter-map
          (lambda (chunk-size)
            (let ((actual (sorted (scan-port* h (open-bytevector-input-port payload)
                                              (bytevector-length payload)
                                              #:chunk-size chunk-size))))
              (and (not (equal? expected actual)) (cons chunk-size actual))))
          (iota 400 1)))
       (test-equal (string-append "chunk sizes around the retained window (" hash ")")
         '()
         (filter-map
          (lambda (chunk-size)
            (let ((actual (sorted (scan-port* h (open-bytevector-input-port payload)
                                              (bytevector-length payload)
                                              #:chunk-size chunk-size))))
              (and (not (equal? expected actual)) (cons chunk-size actual))))
          (list %retained %right-context
                (- %retained 1) (+ %retained 1)
                (- %right-context 1) (+ %right-context 1)
                32 64 63 65 127 128 129))))
     ;; A reference placed exactly at each boundary of a small chunk size.
     (let* ((h (string->utf8 hash))
            (chunk 16))
       (test-equal (string-append "reference at every offset across a boundary (" hash ")")
         '()
         (filter-map
          (lambda (offset)
            (let* ((payload (bytes (make-list offset 90) h (make-list 40 90)))
                   (expected (sorted (sweeps h payload 0 (bytevector-length payload))))
                   (actual (sorted (scan-port* h (open-bytevector-input-port payload)
                                               (bytevector-length payload)
                                               #:chunk-size chunk))))
              (and (not (equal? expected actual)) (cons offset actual))))
          (iota 48)))))
   (list %hash %repeat-hash)))

(test-group "the two scanners agree on real store items"
  ;; The gcc out tree, a glibc, and an item with UTF-16 strings.  These are
  ;; read from the HOST store (/nix/store here), not the test store: the test
  ;; store holds only what the fixtures built.  Reading is all this does.
  ;; Absent items skip the group, and the count below says which happened.
  (define %real-store
    (or (getenv "GOONIX_SCAN_REAL_STORE")
        (let ((candidates '("/nix/store" "/gnu/store")))
          (find (lambda (prefix)
                  (and (file-exists? prefix)
                       (any (lambda (name) (string-contains name "-gcc-"))
                            (or (scandir prefix) '()))))
                candidates))))
  (define (item-directories)
    (and %real-store
         (filter-map
          (lambda (name)
            (and (or (string-contains name "-gcc-")
                     (string-contains name "-glibc-")
                     (string-contains name "-icu4c-")
                     (string-contains name "-wine-")
                     (string-contains name "-mono-"))
                 (let ((path (string-append %real-store "/" name)))
                   (and (file-exists? path) path))))
          (or (scandir %real-store) '()))))
  (define (files-under root limit)
    (let ((result '()) (count 0))
      (let walk ((path root))
        (when (< count limit)
          (let ((stat (false-if-exception (lstat path))))
            (when stat
              (case (stat:type stat)
                ((regular)
                 (when (and (> (stat:size stat) 0)
                            (<= (stat:size stat) (* 2 1024 1024)))
                   (set! result (cons path result))
                   (set! count (+ count 1))))
                ((directory)
                 (for-each (lambda (name)
                             (unless (member name '("." ".."))
                               (walk (string-append path "/" name))))
                           (or (scandir path) '())))
                (else #t))))))
      result))
  (let* ((items (item-directories))
         (files (append-map (lambda (item) (files-under item 12)) items)))
    (format #t "real store items: ~a, files compared: ~a~%"
            (length items) (length files))
    ;; A store without these items (a wiped test store) skips this group
    ;; rather than failing it; the count above says which happened.
    (test-skip (if (pair? files) 0 (* 2 (length files))))
    (for-each
     (lambda (file)
       (let* ((name (basename file))
              ;; The item's own hash: the first 32 characters of its store
              ;; directory name, as scan-store-item takes it.
              (item-root (let loop ((path (dirname file)))
                           (if (string=? path %real-store)
                               #f
                               (let ((parent (dirname path)))
                                 (if (string=? parent %real-store)
                                     path
                                     (loop parent))))))
              (hash (and item-root
                         (string->utf8 (string-take (basename item-root) 32)))))
         (when hash
           (let ((payload (call-with-input-file file get-bytevector-all #:binary #t)))
             (test-equal (string-append "real file " (basename item-root) "/" name)
               (sorted (sweeps hash payload 0 (bytevector-length payload)))
               (sorted (one-pass hash payload)))
             (test-equal (string-append "real file chunked " name)
               (sorted (one-pass hash payload))
               (sorted (scan-port* hash (open-bytevector-input-port payload)
                                   (bytevector-length payload)
                                   #:chunk-size (* 128 1024))))))))
     files)))

(test-end "ca-scan")
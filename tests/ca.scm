;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 7778777 <7778777@7778777.online>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.

(define-module (test-ca)
  #:use-module (guix ca)
  #:use-module (guix ca scan)
  #:use-module (guix scripts ca)
  #:use-module (guix base16)
  #:use-module (guix derivations)
  #:use-module (guix store)
  #:use-module ((guix utils) #:select (call-with-temporary-directory))
  #:use-module (ice-9 match)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 textual-ports)
  #:use-module (json parser)
  #:use-module ((gcrypt hash) #:select (sha256))
  #:use-module ((zlib) #:select (call-with-gzip-output-port))
  #:use-module ((lzma) #:select (call-with-xz-output-port))
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-34)
  #:use-module (srfi srfi-64)
  #:use-module (rnrs bytevectors))

(test-begin "ca")

(define vectors
  (let ((file (or (search-path (or (and=> (getenv "srcdir") list)
                                   '("."))
                               "tests/ca-vectors.json")
                  "tests/ca-vectors.json")))
    (call-with-input-file file json->scm)))

(define (field object name)
  (or (assoc-ref object name)
      (error "missing CA vector field" name)))

(define (list-field object name)
  (let ((value (field object name)))
    (unless (vector? value)
      (error "CA vector field is not a JSON array" name))
    (vector->list value)))

(define (parse-derivation-vector vector)
  (read-derivation
   (open-bytevector-input-port (string->utf8 (field vector "bytes")))
   ;; The input derivation is a path in this vector, not a file to fetch.
   (lambda (path)
     ((@@ (guix derivations) make-derivation)
      '() '() '() "x86_64-linux" "" '() '() path))))

(test-group "upstream's nuke-refs marker is not a goonix name"
  ;; Upstream's remove-store-references writes 32 #\e characters plus #\- as
  ;; its marker.  It is ordinary upstream data, so it is not reserved; and no
  ;; goonix name may BE it, so reserved-hash bumps such a placeholder's last
  ;; character to #\o.  The all-zero-digest vector below must match
  ;; encodeReserved in nix/libstore/ca.cc, which asserts the same string.
  (define (reserved-hash-for-test digest self?)
    ;; reserved-hash is exported so the C++ and Scheme encoders can be
    ;; checked against the same all-zero-digest vector.
    (reserved-hash digest self?))
  (define marker (make-string 32 #\e))
  (define zero-digest (make-bytevector 32 0))
  (test-equal "an all-zero digest encodes to e...eo, never the marker"
    (string-append (string-take marker 31) "o")
    (reserved-hash-for-test zero-digest #f))
  (test-assert "a self token never starts with e, even for an all-zero digest"
    (not (char=? #\e (string-ref (reserved-hash-for-test zero-digest #t) 0))))
  (test-assert "the marker is not a placeholder or a token"
    (parameterize ((%store-prefix "/gnu/store"))
      (let ((path (string-append "/gnu/store/" marker "-hello")))
        (not (or (placeholder-path? path) (token-store-path? path))))))
  (test-assert "the bumped e...eo encoding is still a placeholder"
    (parameterize ((%store-prefix "/gnu/store"))
      (placeholder-path?
       (string-append "/gnu/store/" (string-take marker 31) "o-hello")))))

(test-group "tokens and placeholders"
  (test-assert "self token is deterministic and reserved"
    (let ((token (self-token "out")))
      (and (= 32 (string-length token))
           (not (char=? #\e (string-ref token 0)))
           (string-every (cut string-index "eout" <>) token)
           (string=? token (self-token "out")))))
  (test-assert "self token depends on output name"
    (not (string=? (self-token "out") (self-token "lib"))))
  (test-assert "token paths have store shape"
    (token-store-path? (token-path "out" "hello-1.0")))
  (test-assert "placeholders have store shape"
    (placeholder-path? (placeholder (string->utf8 "drv bytes")
                                    "out" "hello-1.0")))
  (test-equal "token vector matches the shared vectors"
    (field (field vectors "tokens") "out")
    (self-token "out"))
  (test-equal "lib token vector matches the shared vectors"
    (field (field vectors "tokens") "lib")
    (self-token "lib"))
  (test-equal "placeholder vector matches the shared vectors"
    (field (field vectors "placeholder") "hash")
    (let ((vector (field vectors "placeholder")))
      (substring (basename
                  (placeholder
                   (string->utf8 (field vector "derivationBytes"))
                   (field vector "output") (field vector "name")))
                 0 32)))
  (test-assert "self tokens are not placeholders"
    (not (placeholder-path? (token-path "out" "hello-1.0"))))
  (test-equal "placeholder identity is verified"
    (list (string->utf8 "drv bytes") "out" "hello-1.0")
    (placeholder-identity (placeholder (string->utf8 "drv bytes")
                                       "out" "hello-1.0")
                          (string->utf8 "drv bytes") "out" "hello-1.0"))
  (test-assert "invalid token text is rejected"
    (parameterize ((%store-prefix "/gnu/store"))
      (guard (condition (else #t))
        (validate-token-path "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-hello")
        #f)))
  (test-assert "unknown reserved token is rejected"
    (parameterize ((%store-prefix "/gnu/store"))
      (guard (condition (else #t))
        (validate-token-path "/gnu/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-hello")
        #f)))
  (test-assert "real paths do not pass reserved validation"
    (parameterize ((%store-prefix "/gnu/store"))
      (guard (condition (else #t))
        (validate-token-path "/gnu/store/00000000000000000000000000000000-hello")
        #f)))
  (test-assert "a known token at the active store prefix is accepted"
    (string=? (token-path "out" "hello-1.0")
              (validate-token-path (token-path "out" "hello-1.0"))))
  (test-assert "a known placeholder is rejected"
    (guard (condition (else #t))
      (validate-token-path (placeholder (string->utf8 "drv bytes")
                                        "out" "hello-1.0"))
      #f)))

(test-group "tree and content vectors"
  (call-with-temporary-directory
   (lambda (root)
    (for-each
     (lambda (vector)
       (let ((name (field vector "name"))
             (kind (field vector "kind")))
         (let ((path (string-append root "/" name)))
           (match kind
             ("regular"
              (call-with-output-file path
                (lambda (port)
                  (put-bytevector port (u8-list->bytevector
                                        (list-field vector "bytes"))))
                #:binary #t)
              (chmod path (if (= 1 (field vector "executable")) #o555 #o444)))
             ("symlink" (symlink (field vector "target") path))
             ("directory"
              (mkdir path)
              (for-each
               (lambda (entry)
                 (let ((child (string-append path "/" (field entry "name"))))
                   (call-with-output-file child
                     (lambda (port)
                       (put-bytevector port
                                       (u8-list->bytevector
                                        (list-field entry "bytes"))))
                     #:binary #t)
                   (chmod child #o444)))
               (list-field vector "entries"))))
           (test-equal (string-append "shared tree vector: " name)
             (field vector "sha256")
             (bytevector->base16-string (tree-hash path))))))
     (list-field vectors "trees"))
    (let ((ordered (string-append root "/ordered")))
      (mkdir ordered)
      (for-each
       (lambda (pair)
         (call-with-output-file (string-append ordered "/" (car pair))
           (lambda (port) (display (cdr pair) port))))
       '(("z-last" . "z") ("a-first" . "a")))
      (symlink "m-target" (string-append ordered "/m-link"))
      (test-equal "shared directory entry ordering"
        (field (field vectors "orderedDirectory") "sha256")
        (bytevector->base16-string (tree-hash ordered))))
    (let* ((content (field vectors "contentPaths"))
           (trees (list-field vectors "trees"))
           (tree (base16-string->bytevector (field (car trees) "sha256"))))
      (test-equal "shared content path"
        (field content "withoutReferences")
        (parameterize ((%store-prefix "/gnu/store"))
          (content-addressed-path "out" "hello" tree '())))
      (test-equal "shared content path with sorted references"
        (field content "withReferences")
        (parameterize ((%store-prefix "/gnu/store"))
          (content-addressed-path "out" "hello" tree
                                  (reverse (list-field content "references"))))))))
  (let* ((resolved (field vectors "resolvedDerivation"))
         (bytes (string->utf8 (field resolved "bytes")))
         (drv (parse-derivation-vector resolved)))
    (test-equal "shared canonical resolved derivation bytes"
      bytes (derivation->bytevector drv))
    (test-equal "shared resolved-addressed path"
      (field resolved "resolvedPath")
      (parameterize ((%store-prefix "/gnu/store"))
        (resolved-addressed-path "out" "hello" bytes)))
    (test-equal "shared resolved-addressed sibling path"
      (field resolved "resolvedLibPath")
      (parameterize ((%store-prefix "/gnu/store"))
        (resolved-addressed-path "lib" "hello-lib" bytes))))
  (let* ((unresolved (field vectors "unresolvedDerivation"))
         (bytes (string->utf8 (field unresolved "bytes")))
         (drv (parse-derivation-vector unresolved)))
    (test-equal "shared canonical unresolved derivation bytes"
      bytes (derivation->bytevector drv))
    (test-equal "shared unresolved derivation has two outputs"
      '("lib" "out") (map car (derivation-outputs drv)))
    (test-equal "shared unresolved derivation has one input derivation"
      1 (length (derivation-inputs drv)))
    (test-equal "shared placeholder is computed from the unresolved derivation bytes"
      (field unresolved "placeholderHash")
      (substring
       (basename (placeholder bytes (field unresolved "output")
                              (field unresolved "name")))
       0 32))))

(define scan-port-for-test (@@ (guix ca scan) scan-port))
(define scan-bytes-for-test (@@ (guix ca scan) scan-bytes))

(define (sorted-counts counts)
  (sort counts (lambda (a b)
                 (string<? (symbol->string (car a))
                           (symbol->string (car b))))))

(test-group "CA store scanning"
  (call-with-temporary-directory
   (lambda (root)
     (let ((item (string-append root "/0123456789abcdfghijklmnpqrsvwxyz-fixture"))
           (hash "0123456789abcdfghijklmnpqrsvwxyz"))
       (mkdir item)
       (call-with-output-file (string-append item "/whole")
         (lambda (port) (display hash port)))
       (call-with-output-file (string-append item "/fragment")
         (lambda (port) (display (substring hash 3 15) port)))
       (call-with-output-file (string-append item "/encoded")
         (lambda (port)
           (put-bytevector port (string->utf16 hash (endianness little)))))
       (symlink hash (string-append item "/link"))
       (mkdir (string-append item "/" hash))
       (let ((report (scan-store-item item)))
         (test-equal "scanner reports a whole self reference"
           1 (scan-report-full report))
         (test-equal "scanner reports split self-reference fragments"
           #t (> (scan-report-fragments report) 0))
         (test-equal "scanner reports a UTF-16LE self reference"
           1 (scan-report-utf16 report))
         (test-equal "scanner reports a self-reference symlink"
           1 (scan-report-links report))
         (test-equal "scanner reports a self-reference name"
           1 (scan-report-names report))))))
  (call-with-temporary-directory
   (lambda (root)
     (let* ((hash "0123456789abcdfghijklmnpqrsvwxyz")
            (item (string-append root "/" hash "-entries"))
            (named (string-append hash "-named")))
       (mkdir item)
       (call-with-output-file (string-append item "/" named)
         (lambda (port) (display "data" port)))
       (symlink "target" (string-append item "/" hash "-link"))
       (mkdir (string-append item "/" hash "-directory"))
       (test-equal "scanner counts regular, symlink and directory names"
         3 (scan-report-names (scan-store-item item))))))
  (call-with-temporary-directory
   (lambda (root)
     (let* ((hash "0123456789abcdfghijklmnpqrsvwxyz")
            (item (string-append root "/" hash "-empty")))
       (mkdir item)
       (call-with-output-file (string-append item "/empty") (const #t))
       (call-with-output-file (string-append item "/one")
         (lambda (port) (display "x" port)))
       (let ((report (scan-store-item item)))
         (test-equal "scanner excludes empty files from the file counter"
           1 (scan-report-files report))
         (test-equal "scanner still counts empty file bytes as zero"
           1 (scan-report-bytes report))))))
  (call-with-temporary-directory
   (lambda (root)
     (let* ((hash "0123456789abcdfghijklmnpqrsvwxyz")
            (item (string-append root "/" hash "-utf16"))
            (encoded (string->utf16 hash (endianness little))))
       (mkdir item)
       (call-with-output-file (string-append item "/twice")
         (lambda (port) (put-bytevector port encoded)
                 (put-bytevector port encoded))
         #:binary #t)
       (test-equal "scanner counts a UTF-16-containing file once"
         1 (scan-report-utf16 (scan-store-item item))))))
  (call-with-temporary-directory
   (lambda (root)
     (let* ((item (string-append root "/0123456789abcdfghijklmnpqrsvwxyz-boundary"))
            (hash "0123456789abcdfghijklmnpqrsvwxyz")
            (prefix (make-string (- (* 128 1024) 4) #\x)))
       (mkdir item)
       (call-with-output-file (string-append item "/crossing")
         (lambda (port) (display (string-append prefix hash) port)))
       (test-equal "scanner retains a self reference across a read boundary"
         1 (scan-report-full (scan-store-item item))))))
  (let* ((hash "0123456789abcdfghijklmnpqrsvwxyz")
         (bytes (string->utf8 hash))
         (encoded (string->utf16 hash (endianness little)))
         (fragment (string->utf8 (substring hash 3 15)))
         (payload (u8-list->bytevector
                   `(3 0 255
                     ,@(bytevector->u8-list bytes) 7
                     ,@(bytevector->u8-list fragment) 11
                     ,@(bytevector->u8-list encoded) 13
                     ,@(bytevector->u8-list bytes)
                     ,@(bytevector->u8-list fragment) 17
                     ,@(make-list 201 90))))
         (expected (sorted-counts
                    (scan-bytes-for-test (string->utf8 hash) payload))))
    (test-equal "stream scan matches whole-content scan for every small read size"
      '()
      (filter-map
       (lambda (chunk-size)
         (let ((actual (sorted-counts
                        (scan-port-for-test
                         (string->utf8 hash)
                         (open-bytevector-input-port payload)
                         (bytevector-length payload)
                         #:chunk-size chunk-size))))
           (and (not (equal? expected actual))
                (cons chunk-size actual))))
       (iota 400 1))))
  (call-with-temporary-directory
   (lambda (root)
     (let* ((item (string-append root "/0123456789abcdfghijklmnpqrsvwxyz-binary"))
            (hash "0123456789abcdfghijklmnpqrsvwxyz")
            (payload (u8-list->bytevector
                      `(0 255 65 0 ,@(map char->integer (string->list hash))
                          0 128 66))))
       (mkdir item)
       (call-with-output-file (string-append item "/arbitrary")
         (lambda (port) (put-bytevector port payload))
         #:binary #t)
       (let ((report (scan-store-item item)))
         (test-equal "scanner finds a hash among arbitrary bytes"
           1 (scan-report-full report))
         (test-equal "arbitrary-byte fixture is not a false fragment"
           0 (scan-report-fragments report))))))
  (call-with-temporary-directory
   (lambda (root)
     (let* ((item (string-append root "/0123456789abcdfghijklmnpqrsvwxyz-gzip"))
            (hash "0123456789abcdfghijklmnpqrsvwxyz")
            (compressed (string-append item "/member.gz")))
       (mkdir item)
       (call-with-output-file compressed
         (lambda (port)
           (call-with-gzip-output-port port
             (lambda (output) (display hash output)))))
       (test-equal "scanner reports a self reference in a gzip member"
         1 (scan-report-hidden (scan-store-item item))))))
  (call-with-temporary-directory
   (lambda (root)
     (let* ((item (string-append root "/0123456789abcdfghijklmnpqrsvwxyz-xz"))
            (hash "0123456789abcdfghijklmnpqrsvwxyz")
            (compressed (string-append item "/member.xz")))
       (mkdir item)
       (call-with-output-file compressed
         (lambda (port)
           (call-with-xz-output-port port
             (lambda (output) (display hash output)))))
       (test-equal "scanner reports a self reference in an xz member"
         1 (scan-report-hidden (scan-store-item item))))))
  (let ((scan-compressed (@@ (guix ca scan) scan-compressed))
        (hash (string->utf8 "0123456789abcdfghijklmnpqrsvwxyz")))
    (define (compressed-file root name body)
      (let ((file (string-append root "/" name)))
        (call-with-output-file file body)
        file))
    (test-equal "compressed data beyond the scan limit is not silently clean"
      '((hidden . 0) (unsupported . 1))
      (call-with-temporary-directory
       (lambda (root)
         (let ((file (compressed-file
                      root "long.gz"
                      (lambda (port)
                        (call-with-gzip-output-port port
                          (lambda (output)
                            (display (make-string 128 #\x) output)))))))
           (scan-compressed hash file 16)))))
    (test-equal "a truncated gzip member is undecodable"
      1
      (call-with-temporary-directory
       (lambda (root)
         (let ((file (compressed-file
                      root "truncated.gz"
                      (lambda (port)
                        (call-with-gzip-output-port port
                          (lambda (output)
                            (display (make-string 16384 #\x) output)))))))
           (truncate-file file 64)
           (assq-ref (scan-compressed hash file) 'undecodable)))))
    (test-equal "a damaged gzip body is undecodable"
      1
      (call-with-temporary-directory
       (lambda (root)
         (let ((file (compressed-file
                      root "body.gz"
                      (lambda (port)
                        (call-with-gzip-output-port port
                          (lambda (output) (display "contents" output)))))))
           (let ((port (open-file file "r+b")))
             (seek port 10 SEEK_SET)
             (put-bytevector port (make-bytevector 128 255))
             (close-port port))
           (assq-ref (scan-compressed hash file) 'undecodable)))))
    (test-equal "a non-gzip file with a gzip suffix is undecodable"
      1
      (call-with-temporary-directory
       (lambda (root)
         (let ((file (compressed-file root "garbage.gz"
                                      (lambda (port)
                                        (display "not gzip" port)))))
           (assq-ref (scan-compressed hash file) 'undecodable)))))
    (test-equal "concatenated gzip members are not silently incomplete"
      1
      (call-with-temporary-directory
       (lambda (root)
         (let ((first (compressed-file
                       root "first.gz"
                       (lambda (port)
                         (call-with-gzip-output-port port
                           (lambda (output) (display "first" output))))))
               (second (string-append root "/second")))
           (call-with-output-file second
             (lambda (port)
               (call-with-gzip-output-port port
                 (lambda (output) (display "second" output)))))
           (call-with-input-file second
             (lambda (input)
               (let ((output (open-file first "al")))
                 (put-bytevector output (get-bytevector-all input))
                 (close-port output)))
             #:binary #t)
           (assq-ref (scan-compressed hash first) 'unsupported)))))
    (test-equal "a whole gzip member followed by a damaged one is unsupported"
      '((hidden . 0) (unsupported . 1))
      (call-with-temporary-directory
       (lambda (root)
         (let ((file (compressed-file
                      root "second-bad.gz"
                      (lambda (port)
                        (call-with-gzip-output-port port
                          (lambda (output) (display "first" output)))))))
           (call-with-gzip-output-port (open-file file "al")
             (lambda (output) (display "second" output)))
           (let ((port (open-file file "r+b")))
             (seek port (- (stat:size (stat file)) 8) SEEK_SET)
             (put-bytevector port (make-bytevector 4 255))
             (close-port port))
           (scan-compressed hash file)))))
    (test-equal "an empty gzip file is not decoded"
      '()
      (call-with-temporary-directory
       (lambda (root)
         (scan-compressed hash (compressed-file root "empty.gz" (const #t))))))
    (test-equal "an old lzma-alone member is unsupported, not damaged"
      1
      (call-with-temporary-directory
       (lambda (root)
         (let ((file (compressed-file
                      root "old.lzma"
                      (lambda (port) (display "old" port)))))
           (assq-ref (scan-compressed hash file) 'unsupported)))))
    (test-equal "a non-decoder open error escapes unchanged"
      'system-error
      (catch 'system-error
        (lambda () (scan-compressed hash "/no/such/file.gz") #f)
        (lambda _ 'system-error))))
  (call-with-temporary-directory
   (lambda (root)
     (let ((name "0123456789abcdfghijklmnpqrsvwxyz-cli"))
       (mkdir (string-append root "/" name))
       (call-with-output-file (string-append root "/" name "/whole")
         (lambda (port) (display "0123456789abcdfghijklmnpqrsvwxyz" port)))
       (let ((second "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-second"))
         (mkdir (string-append root "/" second))
         (call-with-output-file (string-append root "/" second "/whole")
           (lambda (port) (display "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" port)))
         (test-equal "parallel CLI preserves item order"
           (list name second)
           (let* ((text (call-with-output-string
                         (lambda (port)
                           (parameterize ((current-output-port port))
                             (guix-ca "scan" (string-append "--directory=" root)
                                      "--format=jsonl" "--jobs=3")))))
                  (lines (filter (negate string-null?)
                                 (string-split text #\newline))))
             (map (lambda (line)
                    (assoc-ref (json->scm (open-input-string line)) "item"))
                  lines))))
       (test-equal "guix ca scan emits JSONL"
         (sort
          '(("item" . "0123456789abcdfghijklmnpqrsvwxyz-cli")
            ("files" . 1) ("bytes" . 32) ("full" . 1) ("frag" . 0)
            ("utf16" . 0) ("hidden" . 0) ("names" . 0) ("links" . 0)
            ("undecodable" . 0) ("unsupported" . 0))
          (lambda (a b) (string<? (car a) (car b))))
         (sort
          (json->scm
           (open-input-string
            (call-with-output-string
             (lambda (port)
               (parameterize ((current-output-port port))
                 (guix-ca "scan" (string-append "--directory=" root)
                          "--format=jsonl" name))))))
          (lambda (a b) (string<? (car a) (car b)))))))))

(test-group "build record canonical payload"
  (let* ((vector (field vectors "record"))
         (payload (canonical-build-record-payload
                   (field vector "resolvedHash") (field vector "derivation")
                   (field vector "output") (field vector "path")
                   (field vector "origin")
                   #:relocation-checked?
                   (= 1 (field vector "relocationChecked")))))
    (test-equal "record payload bytes match the shared vectors"
      (u8-list->bytevector (list-field vector "payload")) payload)
    (test-equal "record payload hash matches the shared vectors"
      (field vector "sha256")
      (bytevector->base16-string (sha256 payload)))
    (test-equal "record content hash matches the shared vectors"
      (field vector "sha256")
      (bytevector->base16-string
       (build-record-content-hash
        (field vector "resolvedHash") (field vector "derivation")
        (field vector "output") (field vector "path") (field vector "origin")
        #:relocation-checked? (= 1 (field vector "relocationChecked")))))))
  (test-assert "record payload is field-framed, not concatenated"
    (not (equal? (canonical-build-record-payload "resolved" "derivation"
                                                 "ou" "tpath" "origin")
                 (canonical-build-record-payload "resolved" "derivation"
                                                 "out" "path" "origin"))))
  (test-assert "relocation flag changes the payload"
    (not (equal? (canonical-build-record-payload "r" "d" "out" "p" "o"
                                                 #:relocation-checked? #f)
                 (canonical-build-record-payload "r" "d" "out" "p" "o"
                                                 #:relocation-checked? #t))))
  (test-assert "every signed field changes the payload"
    (let ((base (canonical-build-record-payload "r" "d" "out" "p" "o")))
      (and (not (equal? base (canonical-build-record-payload "r2" "d" "out" "p" "o")))
           (not (equal? base (canonical-build-record-payload "r" "d2" "out" "p" "o")))
           (not (equal? base (canonical-build-record-payload "r" "d" "lib" "p" "o")))
           (not (equal? base (canonical-build-record-payload "r" "d" "out" "p2" "o")))
           (not (equal? base (canonical-build-record-payload "r" "d" "out" "p" "o2"))))))

(test-end)

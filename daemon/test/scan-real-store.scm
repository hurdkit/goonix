;;; goonix: the COMMON ca-scan real-store fixture is fixed and count-stable.
;;;
;;; tests/ca-scan.scm's real-store group reads GOONIX_SCAN_REAL_STORE and its
;;; test count varies with the host store (494 names on z2's small store vs
;;; 12016 on the laptop).  scan-real-store-fixture.scm builds a SMALL FIXED tree
;;; so the group has the same count everywhere.  This test pins the fixture's
;;; contract WITHOUT touching tests/ca-scan.scm (the goonix session's file):
;;;
;;;   1. the generator produces exactly the five selected items (-gcc-, -glibc-,
;;;      -icu4c-, -wine-, -mono-), each a 32-char hash prefix;
;;;   2. every item yields exactly 12 regular files within the group's size
;;;      window (0 < size <= 2 MiB), so the group compares 60 files and runs
;;;      120 real-file assertions, identically on every machine;
;;;   3. two generations are byte-identical (the fixture is a pure function of
;;;      its fixed hashes, no randomness, no host input);
;;;   4. the sweep scanner and the single-pass scanner agree on every fixture
;;;      file, whole and chunked — the same property ca-scan's real-store group
;;;      asserts, here on the fixed tree.
;;;
;;; Daemon-free: the scanner reads bytes, it needs no store connection.
;;;
;;; Usage: guile --no-auto-compile -L <root> -s scan-real-store.scm

(use-modules (guix ca scan)
             (guix build utils)
             (ice-9 binary-ports)
             (ice-9 ftw)
             (ice-9 match)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(define sweeps (@@ (guix ca scan) scan-bytes/sweeps))
(define one-pass (@@ (guix ca scan) scan-bytes))
(define scan-port* (@@ (guix ca scan) scan-port))

(define (sorted counts)
  (sort counts (lambda (a b) (string<? (symbol->string (car a))
                                       (symbol->string (car b))))))

;; Locate the generator next to this test, and the tree root for module loads.
(define here (dirname (car (command-line))))
(define generator (string-append here "/scan-real-store-fixture.scm"))

(define (generate dest)
  (let ((status (system (string-append "guile --no-auto-compile -s "
                                       generator " " dest))))
    (unless (zero? status)
      (error "fixture generator failed" status))))

;; The group's item selection and file walk, mirrored from tests/ca-scan.scm.
(define (item-directories store)
  (filter-map
   (lambda (name)
     (and (or (string-contains name "-gcc-")
              (string-contains name "-glibc-")
              (string-contains name "-icu4c-")
              (string-contains name "-wine-")
              (string-contains name "-mono-"))
          (let ((path (string-append store "/" name)))
            (and (file-exists? path) path))))
   (or (scandir store) '())))

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

(define (tree-fingerprint store)
  ;; A stable digest of every file's relative path + bytes, for the determinism
  ;; check.  Sorted so directory order cannot matter.  The relative path strips
  ;; the store prefix AND the leading slash, so two different store locations
  ;; yield identical fingerprints.
  (let* ((prefix (string-append store "/"))
         (files (sort (filter-map
                       (lambda (path)
                         (and (eq? (stat:type (lstat path)) 'regular) path))
                       (find-files store))
                      string<?)))
    (map (lambda (path)
           (cons (if (string-prefix? prefix path)
                     (string-drop path (string-length prefix))
                     path)
                 (call-with-input-file path get-bytevector-all #:binary #t)))
         files)))

(test-begin "scan-real-store-fixture")

(define store-a (string-append (or (getenv "TMPDIR") "/tmp")
                               "/goonix-scan-fixture-a"))
(define store-b (string-append (or (getenv "TMPDIR") "/tmp")
                               "/goonix-scan-fixture-b"))
(generate store-a)
(generate store-b)

(test-group "the fixture has the fixed shape ca-scan's real-store group selects"
  (let ((items (item-directories store-a)))
    (test-equal "five selected items" 5 (length items))
    (test-assert "one item per name pattern"
      (every (lambda (pattern)
               (any (lambda (item) (string-contains item pattern)) items))
             '("-gcc-" "-glibc-" "-icu4c-" "-wine-" "-mono-")))
    (test-assert "every item directory has a 32-char hash prefix"
      (every (lambda (item)
               (let ((base (basename item)))
                 (and (>= (string-length base) 33)
                      (char=? (string-ref base 32) #\-))))
             items))
    (let ((files (append-map (lambda (item) (files-under item 12)) items)))
      (test-equal "60 files compared (12 per item)" 60 (length files))
      (test-assert "every file is in the size window"
        (every (lambda (file)
                 (let ((size (stat:size (lstat file))))
                   (and (> size 0) (<= size (* 2 1024 1024)))))
               files)))))

(test-group "the fixture is deterministic (two generations byte-identical)"
  (test-equal "same file set and bytes"
    (tree-fingerprint store-a) (tree-fingerprint store-b)))

(test-group "the two scanners agree on every fixture file (the ca-scan property)"
  (let* ((items (item-directories store-a))
         (files (append-map (lambda (item) (files-under item 12)) items)))
    (for-each
     (lambda (file)
       (let* ((item-root (let loop ((path (dirname file)))
                           (if (string=? path store-a)
                               #f
                               (let ((parent (dirname path)))
                                 (if (string=? parent store-a)
                                     path
                                     (loop parent))))))
              (hash (and item-root
                         (string->utf8 (string-take (basename item-root) 32)))))
         (when hash
           (let ((payload (call-with-input-file file get-bytevector-all #:binary #t)))
             (test-equal (string-append "real file " (basename item-root) "/" (basename file))
               (sorted (sweeps hash payload 0 (bytevector-length payload)))
               (sorted (one-pass hash payload)))
             (test-equal (string-append "real file chunked " (basename file))
               (sorted (one-pass hash payload))
               (sorted (scan-port* hash (open-bytevector-input-port payload)
                                   (bytevector-length payload)
                                   #:chunk-size (* 128 1024))))))))
     files)))

;; Clean up the generated trees.
(for-each (lambda (store)
            (false-if-exception
             (system (string-append "chmod -R u+rwX " store " 2>/dev/null; rm -rf " store))))
          (list store-a store-b))

(test-end "scan-real-store-fixture")
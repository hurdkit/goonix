;;; goonix: generate the COMMON ca-scan real-store fixture (deterministic).
;;;
;;; Companion to scan-real-store-fixture.sh.  Creates, under the destination
;;; directory, five store-item directories whose names contain the patterns
;;; tests/ca-scan.scm's real-store group selects (-gcc-, -glibc-, -icu4c-, -wine-,
;;; -mono-), each with a FIXED 32-character hash prefix and a fixed set of regular
;;; files (0 < size <= 2 MiB).  The bytes are a pure function of the item's hash:
;;; no randomness, no host input, so the tree is byte-identical on every machine.
;;;
;;; Each item carries 12 files (the group's per-item cap), so the group compares
;;; 5 * 12 = 60 files and runs 2 * 60 = 120 real-file assertions, identically on
;;; z2 and on the laptop, on the Haskell and the C++ daemon.  The files embed
;;; every reference kind the scanner distinguishes — the whole hash, its 25
;;; eight-byte windows, the UTF-16LE encoding, overlapping and truncated hashes,
;;; and arbitrary filler — so the sweep/single-pass agreement is exercised on
;;; realistic mixed content, not just on empty or uniform bytes.
;;;
;;; Usage: guile --no-auto-compile -s scan-real-store-fixture.scm DEST

(use-modules (ice-9 binary-ports)
             (ice-9 match)
             (rnrs bytevectors)
             (srfi srfi-1))

(define dest (cadr (command-line)))

;; Create the destination (the .sh wrapper wipes it first; running the .scm
;; directly must still work).  Dependency-free recursive mkdir.
(define (ensure-dir path)
  (unless (file-exists? path)
    (ensure-dir (dirname path))
    (mkdir path)))
(ensure-dir dest)

;; Five fixed items, one per selected name pattern.  The 32-char prefixes are
;; valid nix-base32 alphabets (no e/o/t/u), fixed constants, NOT computed from
;; content — the scanner only reads them as the reference hash, it never
;; verifies them against the tree, so any fixed 32 chars work.
(define %items
  '(("0123456789abcdfghijklmnpqrsvwxyz" . "gcc-13.2.0")
    ("abcdefghijklmnopqrstuvwxyz012345" . "glibc-2.39")
    ("zyxwvutsrqponmlkjihgfedcba987654" . "icu4c-73.2")
    ("00112233445566778899aabbccddeeff" . "wine-9.0")
    ("ffeeddccbbaa99887766554433221100" . "mono-6.12.0")))

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
                                             (bytevector->u8-list (string->utf8 piece)))
                                            ((bytevector? piece)
                                             (bytevector->u8-list piece))
                                            (else (list piece))))
                                    part))
                       (else (list part))))
               parts)))

;; The 12 file payloads for an item, as a function of its 32-char hash.  Each is
;; a distinct mix of reference kinds and filler, all deterministic.
(define (payloads hash)
  (let ((h (string->utf8 hash))
        (u (utf16-le hash)))
    (list
     ;; 1: the whole hash alone.
     (bytes h)
     ;; 2: the whole hash twice, separated by filler.
     (bytes h 7 7 7 h)
     ;; 3: overlapping whole hashes (hash + its tail).
     (bytes h (substring hash 1 32))
     ;; 4: every 8-byte window, separated by a zero byte.
     (bytes (append-map (lambda (offset)
                          (list (substring hash offset (+ offset 8)) 0))
                        (iota 25)))
     ;; 5: windows back to back (no separator).
     (bytes (append-map (lambda (offset)
                          (list (substring hash offset (+ offset 8))))
                        (iota 25)))
     ;; 6: the UTF-16LE encoding, twice.
     (bytes u 0 u)
     ;; 7: mixed kinds — full, fragment, utf16, filler.
     (bytes 3 0 255 h 7 (substring hash 3 15) 11 u 13
            h (substring hash 20 28) 17 (make-list 64 90))
     ;; 8: hash among arbitrary bytes.
     (bytes 0 255 65 0 h 0 128 66 0 200 h 1)
     ;; 9: truncated hash at the end (31 of 32 chars).
     (bytes (make-list 40 65) (substring hash 0 31))
     ;; 10: truncated hash at the start.
     (bytes (substring hash 1 32) (make-list 40 66))
     ;; 11: all byte values, then the hash, then filler.
     (bytes (u8-list->bytevector (iota 256)) h (make-list 32 0))
     ;; 12: a larger mixed payload (~64 KiB) with references scattered through
     ;;     filler, to cross the scanner's 128 KiB chunk boundary logic at a
     ;;     smaller scale and exercise retained-context handling.
     (bytes (make-list 1000 65) h (make-list 2000 66)
            (substring hash 5 13) (make-list 3000 67) u
            (make-list 4000 68) h (make-list 5000 69)
            (substring hash 0 8) (make-list 6000 70)
            (substring hash 16 24) (make-list 7000 71) h
            (make-list 8000 72) u (make-list 9000 73)))))

(define (write-file path payload)
  (call-with-output-file path
    (lambda (port) (put-bytevector port payload))
    #:binary #t))

(for-each
 (match-lambda
   ((hash . name)
    (let ((item-dir (string-append dest "/" hash "-" name)))
      (mkdir item-dir)
      ;; A bin/ subdirectory holds the files, as a real store item does; the
      ;; group's files-under walks directories recursively.
      (let ((bin (string-append item-dir "/bin")))
        (mkdir bin)
        (for-each
         (lambda (payload index)
           (write-file (string-append bin "/file-" (number->string index) ".bin")
                       payload))
         (payloads hash)
         (iota 12)))
      ;; One top-level regular file too (the group walks the item root as well).
      (write-file (string-append item-dir "/README")
                  (bytes "fixture item " name " hash " hash)))))
 %items)

(format #t "fixture: ~a items, 12 files each (+1 README), deterministic~%"
        (length %items))
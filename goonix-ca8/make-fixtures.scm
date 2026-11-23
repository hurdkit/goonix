;;; goonix CA-8: fixtures that CALIBRATE the relocation check.
;;;
;;; Three synthetic store-shaped items, each with a self reference of a
;;; different kind.  Their names use the store's 32-character hash shape so the
;;; rewriter treats them as store items.
;;;
;;;   reloc-plain     a literal self path      -> must PASS
;;;   reloc-hashed    a SHA256 of the self path -> must FAIL (plan 4.4: hashed)
;;;   reloc-fragment  the self path in <8-char pieces -> must FAIL (fragments)
;;;
;;; The check normalises the two tokens out before comparing, so a PASS means
;;; the rewriter reached every self dependence, and a FAIL means it did not.

(use-modules (guix ca)
             (guix base32)
             (gcrypt hash)
             (ice-9 format)
             (rnrs bytevectors)
             (srfi srfi-1))

(define %store "/gnu/store")

(define (hash-for name)
  ;; 32 characters of nix-base32: a sha256 in nix-base32 is 52, and the tree's
  ;; reserved-hash alphabet ("eout") is exactly what nix-base32 excludes, so
  ;; neither is a valid store hash for rewrite-directory.
  (substring (bytevector->nix-base32-string
              (sha256 (string->utf8
                       (string-append "goonix-reloc-fixture:" name))))
             0 32))

(define (make-item dir name fill)
  (let* ((h (hash-for name))
         (path (string-append %store "/" h "-" name))
         (root (string-append dir "/" h "-" name)))
    (mkdir root)
    (call-with-output-file (string-append root "/data")
      (lambda (p) (fill p path)))
    (format #t "FIXTURE ~a-~a~%" h name)
    root))

(define (split-into-pieces s n)
  "S split into pieces of at most N characters, joined by newlines."
  (let loop ((i 0) (acc '()))
    (if (>= i (string-length s))
        (string-concatenate-reverse acc)
        (let ((j (min (+ i n) (string-length s))))
          (loop j (cons "\n" (cons (substring s i j) acc)))))))

(let ((dir (cadr (command-line))))
  ;; Control: a plain literal self reference.  The rewriter reaches it, so both
  ;; relocations agree once the tokens are normalised out.
  (make-item dir "reloc-plain"
             (lambda (p self)
               (format p "prefix ~a suffix~%" self)))
  ;; Plan 4.4 "hashed": the self path only appears as a digest.  Rewriting the
  ;; literal path cannot change the digest, so the two copies keep DIFFERENT
  ;; digests (each was computed from its own token) and the check must fail.
  (make-item dir "reloc-hashed"
             (lambda (p self)
               (format p "cache-key ~a~%"
                       (bytevector->nix-base32-string
                        (sha256 (string->utf8 self))))))
  ;; Plan 4.4 "cut into pieces shorter than 8 characters": the path is present
  ;; but never as a contiguous 32-char hash, so the rewriter's pattern misses
  ;; it and the copies differ.
  (make-item dir "reloc-fragment"
             (lambda (p self)
               (format p "pieces:~a~%" (split-into-pieces self 6))))
  (format #t "FIXTURES DONE~%"))
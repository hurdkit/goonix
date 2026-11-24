;;; goonix: self references are rewritten wherever they lie in a file.
(use-modules (guix)
             (guix tests)
             (guix ca)
             (gnu packages bootstrap)
             (ice-9 binary-ports)
             (rnrs bytevectors)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "ca-rewrite")

(define store (open-connection-for-tests))

(define bash
  (add-to-store store "bash" #t "sha256"
                (search-bootstrap-binary "bash" (%current-system))))

(define %chunk (* 128 1024))            ;the daemon's read size

(define (self-reference-at name offset)
  "Build a content-addressed file that holds its own name at OFFSET, with
padding before and after, and return its realised path."
  (let ((drv (derivation store name bash
                         (list "-c"
                               (format #f "{ printf '%*s' ~a ''; \
printf '%s' \"$out\"; printf '%*s' ~a ''; } > \"$out\""
                                       offset %chunk))
                         #:sources (list bash)
                         #:addressing 'content)))
    (build-derivations store (list drv))
    (realised-output-path store drv "out")))

(define (bytes-at file offset count)
  (call-with-input-file file
    (lambda (port)
      (seek port offset SEEK_SET)
      (utf8->string (get-bytevector-n port count)))
    #:binary #t))

(define (reference-rewritten? name offset)
  (let ((file (self-reference-at name offset)))
    (and (not (token-store-path? file))
         (string=? file (bytes-at file offset (string-length file))))))

(test-assert "a self reference at the start of a file"
  (reference-rewritten? "rewrite-start" 0))

;; The hash part of the name begins after the store directory and a slash;
;; put each of its bytes in turn on the first chunk boundary.
(define %hash-start (+ 1 (string-length (%store-prefix))))

(test-assert "a self reference across the first chunk boundary"
  (every (lambda (split)
           (reference-rewritten? (format #f "rewrite-split-~a" split)
                                 (- %chunk %hash-start split)))
         '(1 8 16 24 31)))

(test-assert "a self reference that ends on the chunk boundary"
  (reference-rewritten? "rewrite-ends" (- %chunk %hash-start 32)))

(test-assert "a self reference that begins on the chunk boundary"
  (reference-rewritten? "rewrite-begins" (- %chunk %hash-start)))

(test-end "ca-rewrite")

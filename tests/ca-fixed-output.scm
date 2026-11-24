;;; goonix: a content-addressed derivation with a declared hash is built as a
;;; fixed-output derivation.
(use-modules (guix)
             (guix tests)
             (guix derivations)
             (gnu packages bootstrap)
             ((gcrypt hash) #:select (sha256))
             (rnrs bytevectors)
             (srfi srfi-34)
             (srfi srfi-64)
             (ice-9 textual-ports))

(test-begin "ca-fixed-output")

(define store (open-connection-for-tests))
(%graft? #f)

(define bash
  (add-to-store store "bash" #t "sha256"
                (search-bootstrap-binary "bash" (%current-system))))

;; The test environment sets this variable for the daemon and for us.
(define variable "GUIX_STATE_DIRECTORY")

(define (fresh-name prefix)
  ;; A new name on every run: the test store outlives a run, and a fixed
  ;; output that is already there is not built again.
  (string-append prefix "-"
                 (number->string (random 1000000000
                                         (random-state-from-platform)))))

(define (leaked-value addressing)
  ;; Build a fixed output whose content is the daemon's value of VARIABLE,
  ;; which only a fixed-output build may see, and return that content.
  (let ((drv (derivation store (fresh-name "ca-fixed-leak") bash
                         (list "-c"
                               (string-append "printf %s \"$" variable
                                              "\" > \"$out\""))
                         #:sources (list bash)
                         #:hash (sha256 (string->utf8 (getenv variable)))
                         #:hash-algo 'sha256
                         #:leaked-env-vars (list variable)
                         #:addressing addressing)))
    (guard (condition ((store-protocol-error? condition) 'build-failed))
      (build-derivations store (list drv))
      (call-with-input-file (derivation->output-path drv) get-string-all))))

(test-equal "an input-addressed fixed output sees a leaked variable"
  (getenv variable)
  (leaked-value 'input))

(test-equal "a content-addressed fixed output sees a leaked variable"
  (getenv variable)
  (leaked-value 'content))

(close-connection store)
(test-end)

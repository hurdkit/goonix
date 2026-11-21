(use-modules (guix store) (guix derivations) (srfi srfi-34))
(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options store #:use-substitutes? #f #:offload? #f)
(define source (add-text-to-store store "missing-builder-source" "input\n"))
;; This is a missing path in a valid store item's directory, not a host path.
(define missing (string-append (dirname source) "/missing-builder"))
(define drv (derivation store "missing-builder" missing '()
                        #:sources (list source)))
(define message
  (guard (condition
          ((store-protocol-error? condition)
           (unless (= 100 (store-protocol-error-status condition))
             (error "missing builder returned the wrong status"
                    (store-protocol-error-status condition)))
           (store-protocol-error-message condition)))
    (build-derivations store (list drv))
    (error "missing builder unexpectedly succeeded")))
(define expected (string-append "build of `" (derivation-file-name drv) "' failed"))
(unless (string=? expected message)
  (error "missing builder client message differs" message expected))
(format #t "missing-builder client status and message: PASS~%")
(close-connection store)

;; Regression: add-text-to-store must reject an invalid store name with a
;; store-protocol-error whose message contains "invalid character", as C++ does.
;;
;; addTextToStore (operation 8) computed the text path and wrote it without
;; validating the name.  C++ checkStoreName runs inside makeStorePath
;; (store-api.cc), which computeStorePathForText calls, so an invalid name is
;; rejected with "invalid character `X' in name `...'".  The inferior
;; "&store-protocol-error" test requires that message.  The fix validates the
;; name in addTextToStore before computing the path.
(use-modules (guix store) (srfi srfi-13) (srfi srfi-34))

(define (assert condition message)
  (unless condition (error message)))

(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options store #:use-substitutes? #f)
;; An invalid name (| / ? ! @ are not all valid; | is invalid).
(define result
  (guard (c ((store-protocol-error? c)
             (store-protocol-error-message c)))
    (add-text-to-store store "we|rd/?!@" "uh uh")
    #f))
(assert (and (string? result) (string-contains result "invalid character"))
        (string-append "expected a store-protocol-error containing 'invalid character', got: "
                       (format #f "~s" result)))
(close-connection store)
(display "invalid-name rejected: PASS\n")
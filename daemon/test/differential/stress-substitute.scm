;;; goonix stress gate: the substitute client.  Queries the local HTTP server
;;; through the noisy helper (floods the log, then stays silent).  Args: SOCKET PAYLOAD-HASH
(use-modules (guix store) (guix derivations) (guix monads) (guix download)
             (guix base32) (gnu packages bootstrap) (ice-9 match))
(define socket (cadr (command-line)))
(define payload-hash-b32 (caddr (command-line)))
(define s (open-connection socket))
(set-build-options s #:use-substitutes? #t #:offload? #f
                   #:substitute-urls '("http://127.0.0.1:18080"))
(define url "http://127.0.0.1:18080/payload.txt")
(define hash (nix-base32-string->bytevector payload-hash-b32))
(define drv ((store-lower url-fetch) s url 'sha256 hash #:guile %bootstrap-guile))
(define out (derivation->output-path drv))
;; has-substitutes? asks the helper, which floods the log then stays silent.
(define have (has-substitutes? s out))
(close-connection s)
(format #t "substitute: PASS (have-substitutes=~a)~%" have)
(primitive-exit 0)
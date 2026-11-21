(use-modules (guix store) (ice-9 rdelim))

(unless (equal? (getenv "HS7_PHASE") "hold") (error "unexpected phase"))

(define store (open-connection (getenv "HS7_HOLDER_SOCKET")))
(define fixture (getenv "HS7_FIXTURE"))
(let ((path (add-text-to-store store "hs7-disconnected-root"
                               "root expires with this client")))
  (add-temp-root store path)
  (call-with-output-file (string-append fixture "/held-path")
    (lambda (port) (display path port) (newline port)))
  (call-with-output-file (string-append fixture "/holder-ready")
    (lambda (port) (display path port) (newline port))))
(close-connection store)

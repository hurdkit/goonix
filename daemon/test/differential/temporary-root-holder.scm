(use-modules (guix store) (ice-9 textual-ports))

(unless (equal? (getenv "HS7_PHASE") "hold") (error "unexpected phase"))

(define socket (getenv "HS7_HOLDER_SOCKET"))
(define store (open-connection socket))
(let ((path (add-text-to-store store "hs7-live-temp-root" "held by a live connection")))
  (add-temp-root store path)
  (unless (valid-path? store path) (error "root was not registered"))
  (call-with-output-file (string-append (getenv "HS7_FIXTURE") "/held-path")
    (lambda (port) (display path port) (newline port)))
  (call-with-output-file (string-append (getenv "HS7_FIXTURE") "/holder-ready")
    (lambda (port) (display path port) (newline port)))
  ;; Keep the root's descriptor and read lock alive while the other daemon GCs.
  (let loop () (sleep 3600) (loop)))

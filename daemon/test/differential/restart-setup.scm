(use-modules (guix store) (ice-9 textual-ports))

(define (assert condition message)
  (unless condition (error message)))

(with-store store
  (let* ((reference (add-text-to-store store "hs7-restart-reference" "reference"))
         (root (add-text-to-store store "hs7-restart-root" "root" (list reference)))
         (dead (add-text-to-store store "hs7-restart-dead" "dead"))
         (link (string-append (getenv "HS7_FIXTURE") "/restart-root")))
    (symlink root link)
    (add-indirect-root store link)
    (call-with-output-file (string-append (getenv "HS7_FIXTURE") "/restart-paths")
      (lambda (port) (format port "~a\n~a\n~a\n" root reference dead)))
    (format #t "HS-7 restart setup: PASS\n")))

;; Two shells that differ, a package that is no shell, and a variable that
;; only the default shell sets.
(flake (format 1)
 (outputs (lambda (in)
  (use-modules (guix tests) (guix build-system trivial)
               (gnu packages bootstrap))
  (define (tool name)
    (dummy-package name
      (build-system trivial-build-system)
      (arguments
       (quasiquote
        (#:guile ,%bootstrap-guile
         #:builder
         (begin
           (mkdir %output)
           (mkdir (string-append %output "/bin"))
           (call-with-output-file (string-append %output "/bin/" ,name)
             (lambda (port) (display ,name port)))
           #t))))))
  (define one (tool "flake-tool-one"))
  (define two (tool "flake-tool-two"))
  `((packages (tool . ,two))
    (shells (default . ,(shell (packages (list one))
                               (environment '(("FLAKE_SHELL" . "default")))))
            (other . ,(shell (packages (list two)))))))))

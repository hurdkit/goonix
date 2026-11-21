;; Open two real builders, each with a child, then disconnect without a release.
(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap) (ice-9 threads) (srfi srfi-34))
(define (report-failure condition)
  (format (current-error-port) "engine-disconnect client failed: ~s~%" condition)
  (force-output (current-error-port))
  (raise condition))
(guard (condition (else (report-failure condition)))
(define fixture (getenv "HS4_SCHEDULER_FIXTURE"))
(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options store #:use-substitutes? #f #:offload? #f #:max-build-jobs 2)
(%graft? #f)
(define shell (add-to-store store "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))
(define (make-drv name)
  (let ((script (add-text-to-store store (string-append name ".sh")
                  (string-append
                    "printf '%s\\n' $$ > '" fixture "/" name ".pid'\n"
                    "printf '%s\\n' $out > '" fixture "/" name ".output'\n"
                    "printf started > '" fixture "/" name ".started'\n"
                    "'" shell "' -c 'while ! test -e \"" fixture "/release-builders\"; do read -t 1 _ < \"" fixture "/tick\" || true; done' &\n"
                    "printf '%s\\n' $! > '" fixture "/" name ".child.pid'\n"
                    "while ! test -e '" fixture "/release-builders'; do\n"
                    "  read -t 1 _ < '" fixture "/tick' || true\n"
                    "done\n"
                    "printf done > $out\n"))))
    (let ((drv (derivation store name shell (list "-e" script)
                           #:sources (list shell script))))
      (call-with-output-file (string-append fixture "/" name ".drv")
        (lambda (port) (display (derivation-file-name drv) port) (newline port)))
      drv)))
(build-derivations store (list (make-drv "disconnect-left")
                              (make-drv "disconnect-right"))))

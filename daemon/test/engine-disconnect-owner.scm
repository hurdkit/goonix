;; The first client owns a blocked build; the harness closes this process.
(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap) (srfi srfi-34))
(define (report-failure condition)
  (format (current-error-port) "disconnect owner failed: ~s~%" condition)
  (force-output (current-error-port))
  (raise condition))
(guard (condition (else (report-failure condition)))
(define fixture (getenv "HS4_SCHEDULER_FIXTURE"))
(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options store #:use-substitutes? #f #:offload? #f)
(%graft? #f)
(define shell (add-to-store store "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))
(define script
  (add-text-to-store store "shared-disconnect-builder.sh"
    (string-append
      "printf started > '" fixture "/shared-started'\n"
      "while ! test -e '" fixture "/release-shared'; do\n"
      "  read -t 1 _ < '" fixture "/tick' || true\n"
      "done\n"
      "printf shared > $out\n")))
(define shared (derivation store "shared-disconnect-builder" shell
                           (list "-e" script) #:sources (list shell script)))
(call-with-output-file (string-append fixture "/shared-output")
  (lambda (port) (display (derivation->output-path shared) port) (newline port)))
(call-with-output-file (string-append fixture "/shared-drv")
  (lambda (port) (display (derivation-file-name shared) port) (newline port)))
(build-derivations store (list shared)))

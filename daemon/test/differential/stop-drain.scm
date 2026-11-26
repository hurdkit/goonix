;; The client of stop-drain.sh.  One connection stays idle; on the other a
;; build is started whose builder waits to be let go.  The script signals the
;; daemon while that builder runs.  build-derivations has to return, and the
;; output has to be valid on the same connection.
(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap))

(define fixture (getenv "STOP_DRAIN_FIXTURE"))
(define (in-fixture name) (string-append fixture "/" name))
(define (say text) (display text) (newline) (force-output))
(define (touch file) (call-with-output-file file (const #t)))

(define (connect)
  (let ((store (open-connection (getenv "GUIX_DAEMON_SOCKET"))))
    (set-build-options store #:use-substitutes? #f #:offload? #f)
    store))

(%graft? #f)
(define idle (connect))
(define store (connect))
(define shell (add-to-store store "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))
(define script
  (add-text-to-store store "stop-drain-builder.sh"
    (string-append
     ": > '" (in-fixture "builder-started") "'\n"
     "while ! test -e '" (in-fixture "builder-may-finish") "'; do\n"
     "  read -t 1 _ < '" (in-fixture "tick") "' || true\n"
     "done\n"
     "printf done > \"$out\"\n")))
(define drv
  (derivation store "stop-drain" shell (list "-e" script)
              #:sources (list shell script)))

(build-derivations store (list drv))
(unless (valid-path? store (derivation->output-path drv))
  (error "the output is not valid after build-derivations returned"))
(say "build returned, output valid")
(touch (in-fixture "client-built"))

;; Stay connected until the script has looked at the daemon.
(let loop ()
  (unless (file-exists? (in-fixture "client-may-leave"))
    (usleep 50000)
    (loop)))
;; The idle connection was open through all of it and still answers.
(unless (valid-path? idle (derivation->output-path drv))
  (error "the idle connection does not see the output"))
(close-connection store)
(close-connection idle)
(say "client done")

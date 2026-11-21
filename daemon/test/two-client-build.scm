;; Two clients of one daemon. Output locks, not a shared scheduler, must
;; serialize the builder; the waiter rechecks validity after acquiring it.
(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap) (ice-9 threads) (ice-9 rdelim)
             (ice-9 textual-ports) (srfi srfi-34))
(define fixture (getenv "HS4_SCHEDULER_FIXTURE"))
(define first (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(define second (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(for-each (lambda (s) (set-build-options s #:use-substitutes? #f #:offload? #f #:max-build-jobs 2))
          (list first second))
(%graft? #f)
(define shell (add-to-store first "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))
(define script
  (add-text-to-store first "two-client-builder.sh"
    (string-append
      "printf 'run\\n' >> '" fixture "/builder-runs'\n"
      "printf started > '" fixture "/builder-started'\n"
      "while ! test -e '" fixture "/release-builder'; do\n"
      "  if read -t 1 _ < '" fixture "/tick'; then :; fi\n"
      "done\n"
      "printf done > $out\n")))
(define shared
  (derivation first "two-client-builder" shell (list "-e" script)
              #:sources (list shell script)))
(define (build s)
  (guard (condition ((store-protocol-error? condition)
                     (error "two-client build failed" (store-protocol-error-message condition))))
    (build-derivations s (list shared))))
(define thread-one (begin-thread (build first)))
;; Wait for the first builder to own the output lock, then make a second
;; independent client request for the same derivation.
(let loop ((n 0))
  (unless (file-exists? (string-append fixture "/builder-started"))
    (when (> n 100) (error "first builder did not start"))
    (usleep 100000)
    (loop (+ n 1))))
(define thread-two (begin-thread (build second)))
(usleep 500000)
(call-with-output-file (string-append fixture "/release-builder")
  (lambda (port) (display "release\n" port)))
(join-thread thread-one)
(join-thread thread-two)
(unless (valid-path? second (derivation->output-path shared))
  (error "second client did not receive valid output"))
(define runs (call-with-input-file (string-append fixture "/builder-runs") get-string-all))
(unless (string=? runs "run\n") (error "same derivation built more than once" runs))
(format #t "HS-4 two-client output lock and validity recheck: PASS~%")
(close-connection first)
(close-connection second)

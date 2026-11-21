;; HS-12 goal-sharing mode rule: goals are shared only between Normal-mode
;; requests.  A (normal) and B (check) on the same derivation at the same time:
;; B's check really runs (the builder runs twice), and a non-deterministic builder
;; makes B's check fail.  With the pre-fix goal sharing B would attach to A's
;; normal goal and "succeed" without checking anything.
(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap) (ice-9 threads) (ice-9 rdelim)
             (ice-9 textual-ports) (srfi srfi-1) (srfi srfi-34))

(define (assert condition message)
  (unless condition (error message)))

(define fixture (getenv "HS12_GOAL_FIXTURE"))

(define (marker name)
  (call-with-output-file (string-append fixture "/" name)
    (lambda (port) (display "done" port) (newline port))))

(define (wait-marker name)
  (let loop ()
    (unless (file-exists? (string-append fixture "/" name))
      (usleep 5000) (loop))))

(define (release)
  (call-with-output-file (string-append fixture "/release-builder")
    (lambda (port) (display "release" port) (newline port))))

(%graft? #f)
(define a (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options a #:use-substitutes? #f #:offload? #f #:max-build-jobs 2)
(define shell (add-to-store a "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))

;; A non-deterministic builder: it writes its own PID ($$) to $out, so the second
;; build produces a different output.  Only bash builtins are used (the builder
;; PATH is /path-not-set).  The first build blocks until released so B's check
;; overlaps A's goal; B's check build waits on the output lock and runs after A
;; registers, so it compares against A's valid output.
(define script
  (add-text-to-store a "goal-mode-builder.sh"
    (string-append
      "printf started >> '" fixture "/builder-runs'\n"
      "if test -e '" fixture "/first-started'; then\n"
      "  : second build\n"
      "else\n"
      "  printf first > '" fixture "/first-started'\n"
      "  while ! test -e '" fixture "/release-builder'; do\n"
      "    read -t 1 _ < '" fixture "/tick' || true\n"
      "  done\n"
      "fi\n"
      "printf '%s' \"$$\" > \"$out\"\n")))
(define drv (derivation a "goal-mode-nondet" shell (list "-e" script)
                        #:sources (list shell script)))
(define out (derivation->output-path drv))

;; A builds normally in a thread; its builder blocks until released.
(define build-a-thread
  (call-with-new-thread
    (lambda ()
      (guard (c (#t (marker "build-a-failed")))
        (build-derivations a (list drv))
        (marker "build-a-done")))))
(wait-marker "first-started")

;; B asks for a CHECK of the same derivation while A's normal goal runs.  B must
;; run its own check build (not attach to A's goal).
(define b (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options b #:use-substitutes? #f #:offload? #f #:max-build-jobs 2)
(define check-b-thread
  (call-with-new-thread
    (lambda ()
      (guard (c ((store-protocol-error? c)
                 (call-with-output-file (string-append fixture "/check-b-error")
                   (lambda (port) (display (store-protocol-error-message c) port)))
                 (marker "check-b-failed"))
                (else (marker "check-b-other-error")))
        (build-things b (list (derivation-file-name drv)) (build-mode check))
        (marker "check-b-succeeded")))))
;; Let B's check start, then release A's builder so both proceed.
(usleep 200000)
(release)
(join-thread build-a-thread)
(join-thread check-b-thread)

(assert (not (file-exists? (string-append fixture "/build-a-failed"))) "A normal build failed")
(assert (file-exists? (string-append fixture "/build-a-done")) "A normal build did not finish")
;; B's check must really run and FAIL on the non-deterministic builder.
(assert (not (file-exists? (string-append fixture "/check-b-succeeded")))
        "B check attached to A's normal goal and succeeded without checking")
(assert (file-exists? (string-append fixture "/check-b-failed"))
        "B check did not fail on the non-deterministic builder")
(define check-error
  (call-with-input-file (string-append fixture "/check-b-error") get-string-all))
(assert (string-contains check-error "deterministic")
        "B check failure is not the non-determinism error")
;; The builder ran twice: A's normal build and B's check build.
(define builder-runs
  (call-with-input-file (string-append fixture "/builder-runs") get-string-all))
(assert (string=? builder-runs "startedstarted")
        (string-append "builder did not run twice (builder-runs=" builder-runs ")"))
;; A's normal output remains valid (check mode does not register).
(assert (valid-path? a out) "A's normal output became invalid after the check")
(close-connection b)
(close-connection a)
(format #t "HS-12 goal mode rule: PASS~%")
(force-output)
(primitive-exit 0)
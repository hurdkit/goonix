;; HS-12 goal-sharing failure rule: only SUCCESS is shared.  A with
;; max-silent-time 1 on a builder that sleeps 3 s, and B with no limit, both on
;; the same derivation: A fails (its silent-time limit), B succeeds (its own
;; attempt with its own settings).  With the pre-fix goal sharing B would take
;; A's failure instead of building again.
(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap) (ice-9 threads) (ice-9 rdelim)
             (ice-9 textual-ports) (srfi srfi-1) (srfi srfi-34))

(define (assert condition message)
  (unless condition (error message)))

(define fixture (getenv "HS12_GOAL_FIXTURE"))

(define (marker name)
  (call-with-output-file (string-append fixture "/" name)
    (lambda (port) (display "done" port) (newline port))))

(%graft? #f)
(define a (open-connection (getenv "GUIX_DAEMON_SOCKET")))
;; A's silent-time limit is 1 s; the builder is silent for 3 s, so A fails.
(set-build-options a #:use-substitutes? #f #:offload? #f #:max-build-jobs 2
                   #:max-silent-time 1)
(define shell (add-to-store a "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))

;; A builder that is silent for 3 s (read -t 3 from the tick fifo), then writes
;; $out.  Only bash builtins are used (the builder PATH is /path-not-set).
(define script
  (add-text-to-store a "goal-failure-builder.sh"
    (string-append
      "printf started >> '" fixture "/builder-runs'\n"
      "read -t 3 _ < '" fixture "/tick' || true\n"
      "printf done > \"$out\"\n")))
(define drv (derivation a "goal-failure-silent" shell (list "-e" script)
                        #:sources (list shell script)))
(define out (derivation->output-path drv))

;; A builds in a thread; its silent-time limit kills the builder after 1 s.
(define build-a-thread
  (call-with-new-thread
    (lambda ()
      (guard (c ((store-protocol-error? c)
                 (call-with-output-file (string-append fixture "/build-a-error")
                   (lambda (port) (display (store-protocol-error-message c) port)))
                 (marker "build-a-failed"))
                (else (marker "build-a-other-error")))
        (build-derivations a (list drv))
        (marker "build-a-succeeded")))))

;; B requests the same derivation while A's goal runs, with NO silent-time limit.
;; B attaches to A's goal; when A fails, B must run its OWN attempt and succeed.
(usleep 300000)
(define b (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options b #:use-substitutes? #f #:offload? #f #:max-build-jobs 2)
(define build-b-thread
  (call-with-new-thread
    (lambda ()
      (guard (c (#t (marker "build-b-failed")))
        (build-derivations b (list drv))
        (marker "build-b-succeeded")))))

(join-thread build-a-thread)
(join-thread build-b-thread)

;; A failed on its silent-time limit.
(assert (file-exists? (string-append fixture "/build-a-failed"))
        "A did not fail on its max-silent-time limit")
(assert (not (file-exists? (string-append fixture "/build-a-succeeded")))
        "A succeeded despite its max-silent-time limit")
;; B succeeded by running its own attempt with its own (no limit) settings.
(assert (file-exists? (string-append fixture "/build-b-succeeded"))
        "B took A's failure instead of building again with its own settings")
(assert (not (file-exists? (string-append fixture "/build-b-failed")))
        "B failed though it has no silent-time limit")
(assert (valid-path? b out) "B's output is not valid")
;; The builder ran twice: A's killed attempt and B's successful attempt.
(define builder-runs
  (call-with-input-file (string-append fixture "/builder-runs") get-string-all))
(assert (string=? builder-runs "startedstarted")
        (string-append "builder did not run twice (builder-runs=" builder-runs ")"))
(close-connection b)
(close-connection a)
(format #t "HS-12 goal failure rule: PASS~%")
(force-output)
(primitive-exit 0)
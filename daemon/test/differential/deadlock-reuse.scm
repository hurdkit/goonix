;; Regression: a derivation whose output is already valid must not be rebuilt
;; when the build-hook offer returns BuildLocally.
;;
;; buildWithHook's hook-offer path (tryBuild with a hook pool) returned
;; BuildLocally both when `offer` found the output already valid and when the
;; hook declined, and the caller ran localBuild unconditionally.  localBuild
;; deletes the output path and rebuilds it, so a second client building the same
;; derivation deleted a path a concurrent build was using (the store-deadlock
;; test: bootstrap-Guile re-unpacked mid-exec, "No such file or directory" /
;; ".guile-real: Permission denied", deadlock).  C++ re-checks validity after
;; acquiring the output locks and skips a valid output (DerivationGoal::
;; tryToBuild, "someone beat us to it").  The fix re-checks allOutputsValid in
;; the BuildLocally case, inside the same output locks.
;;
;; The hook pool must be active for the bug path: do NOT set #:offload? #f
;; (that disables build-use-build-hook and selects tryBuild Nothing, which
;; already re-checked validity, so the test would pass on the old daemon too).
;;
;; Deterministic overlap with a gate file:
;;   - the builder appends one line to the marker, then waits (bash builtins)
;;     until "$fixture/release" exists, then writes $out;
;;   - client A starts; the test waits until the marker has one line, so A holds
;;     the output lock and the output is not valid yet;
;;   - client B starts; B's discovery sees an invalid output and B waits on the
;;     output lock;
;;   - the test creates the release file; A finishes and registers, B acquires
;;     the lock, its hook offer finds the output valid and returns BuildLocally;
;;   - join both clients and assert exactly one marker line.
;; On the old daemon B rebuilds (two marker lines, and A's output is deleted
;; mid-build); on the fixed daemon B reuses A's output (one line).
(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap) (ice-9 textual-ports) (srfi srfi-1) (ice-9 threads))

(define (assert condition message)
  (unless condition (error message)))

(define fixture (getenv "HS_DEADLOCK_FIXTURE"))
(define marker (string-append fixture "/builds"))
(define release (string-append fixture "/release"))
(define shell-path (search-bootstrap-binary "bash" "x86_64-linux"))

(define (marker-count)
  (if (file-exists? marker)
      (length (call-with-input-file marker
                (lambda (port)
                  (let loop ((line (get-line port)) (acc '()))
                    (if (eof-object? line) (reverse acc)
                        (loop (get-line port) (cons line acc)))))))
      0))

(define drv
  (let ((store (open-connection (getenv "GUIX_DAEMON_SOCKET"))))
    (set-build-options store #:use-substitutes? #f)
    (%graft? #f)
    (let* ((shell (add-to-store store "bash" #t "sha256" shell-path))
           (script (add-text-to-store store "deadlock-builder.sh"
                     (string-append "printf 'built\\n' >> " marker "\n"
                                    ;; Wait for the gate with bash builtins only
                                    ;; (the build PATH has no sleep).  `read -t`
                                    ;; returns non-zero on timeout, so guard it.
                                    "while [ ! -e " release " ]; do\n"
                                    "  read -t 0.1 _ < /dev/null || true\n"
                                    "done\n"
                                    "printf 'ok\\n' > \"$out\"\n"))))
      (derivation store "deadlock-reuse" shell (list "-e" script)
                  #:sources (list shell script)))))

(define (builder)
  (call-with-new-thread
    (lambda ()
      (let ((store (open-connection (getenv "GUIX_DAEMON_SOCKET"))))
        (set-build-options store #:use-substitutes? #f)
        (build-derivations store (list drv))
        (close-connection store)
        'done))))

;; Client A starts building and holds the output lock at the gate.
(define t1 (builder))
;; Wait until A's builder has appended the marker (A is inside the build).
(let loop ((i 0))
  (cond ((>= (marker-count) 1) #t)
        ((> i 600) (error "client A never started building"))
        (else (usleep 100000) (loop (+ i 1)))))
;; Client B now decides to build (output invalid) and waits on the output lock.
(define t2 (builder))
;; Give B time to reach the lock wait before A registers.
(usleep 500000)
;; Release A: it finishes and registers; B then acquires the lock and its hook
;; offer finds the output valid.
(call-with-output-file release (lambda (port) (display "go\n" port)))
(define deadline (+ (current-time) 60))
(define r1 (join-thread t1 deadline 'timeout))
(define r2 (join-thread t2 deadline 'timeout))
(assert (and (eq? r1 'done) (eq? r2 'done))
        "a concurrent build timed out (deadlock)")
(assert (= 1 (marker-count))
        (string-append "derivation rebuilt by the second client (builds="
                       (number->string (marker-count)) ", expected 1)"))
(display "deadlock reuse-valid-output: PASS\n")
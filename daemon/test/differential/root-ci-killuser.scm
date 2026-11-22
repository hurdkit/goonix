;; PR #6 killUser reproduction client.  Run inside the user namespace as a
;; client WITHOUT GUIX_LOG_DIRECTORY, against a daemon with --build-users-group
;; and --max-jobs=2 (chroot ON).  Adds the CI runner conditions ONE AT A TIME and
;; records each case name + result.  The daemon's post-build sweep (killUser)
;; must succeed; a failure carries the failing step (diagnostic commit).
;;
;; Args: WORK-DIR
(use-modules (guix store) (guix derivations) (guix monads) (guix download)
             (guix hash) (guix base32) (guix tests) (guix utils)
             (gnu packages bootstrap) (gcrypt hash) (rnrs io ports) (rnrs bytevectors)
             (ice-9 match) (ice-9 textual-ports) (ice-9 string-fun)
             (srfi srfi-1) (srfi srfi-34))

(define work (cadr (command-line)))
(define store (open-connection))
(set-build-options store #:use-substitutes? #f)
(%graft? #f)

(define results '())
(define (record name ok)
  (set! results (cons (cons name ok) results))
  (format #t "~a: ~a~%" name (if ok "PASS" "FAIL")))

(define (build-ok drv)
  (guard (c (else (format #t "  build error: ~a~%" c) #f))
    (build-derivations store (list drv))
    (valid-path? store (derivation->output-path drv))))

(define bash (add-to-store store "bash" #t "sha256"
                           (search-bootstrap-binary "bash" (%current-system))))

;; (a) two builds at once (--max-jobs=2), two leases sweeping at the same time.
;; Two independent derivations submitted together; the daemon runs them on two
;; build users concurrently and sweeps each after its build.
(record "a-two-concurrent-builds"
  (guard (c (else (format #t "  concurrent error: ~a~%" c) #f))
    (let* ((d1 (derivation store "ku-a1" bash '("-c" "echo a1 > $out")
                           #:sources (list bash)))
           (d2 (derivation store "ku-a2" bash '("-c" "echo a2 > $out")
                           #:sources (list bash))))
      (build-derivations store (list d1 d2))
      (and (valid-path? store (derivation->output-path d1))
           (valid-path? store (derivation->output-path d2))))))

;; (b) a builtin download followed by ordinary builds under the same user pool.
;; The served payload is "download payload\n" (root-ci-setup.sh).  The builtin
;; runs under a build user (perform-download), then ordinary builds reuse the
;; pool, each sweeping after its build.
(record "b-builtin-then-ordinary"
  (guard (c (else (format #t "  builtin+ordinary error: ~a~%" c) #f))
    (let* ((text "download payload\n")
           (drv (derivation store "ku-b-download" "builtin:download" '()
                  #:env-vars `(("url" . ,(object->string "http://127.0.0.1:18080/payload.txt")))
                  #:hash-algo 'sha256 #:hash (sha256 (string->utf8 text))))
           (o1 (derivation store "ku-b-ord1" bash '("-c" "echo ord1 > $out")
                 #:sources (list bash)))
           (o2 (derivation store "ku-b-ord2" bash '("-c" "echo ord2 > $out")
                 #:sources (list bash))))
      (and (build-ok drv) (build-ok o1) (build-ok o2)))))

;; (c) a long build with many processes and threads (guild-compile-like): the
;; builder forks a pool of background workers that churn briefly, mimicking the
;; goonix package build's compile workers, then exits.  The post-build sweep must
;; clean up any worker still running under the build user.
(record "c-many-processes-threads"
  (guard (c (else (format #t "  many-procs error: ~a~%" c) #f))
    (let* ((script
            (string-append
             "for i in 1 2 3 4 5 6 7 8; do\n"
             "  ( n=0; while [ $n -lt 200000 ]; do n=$((n+1)); done ) &\n"
             "done\n"
             "wait\n"
             "echo many > $out\n"))
           (drv (derivation store "ku-c-many" bash (list "-c" script)
                  #:sources (list bash))))
      (build-ok drv))))

;; (d) a builder that leaves a process behind: a setsid'd background sleep that
;; outlives the builder.  The post-build sweep must kill it (kill(-1) under the
;; build uid).  This is the leftover-process case.
(record "d-setsid-leftover"
  (guard (c (else (format #t "  setsid-leftover error: ~a~%" c) #f))
    (let* ((script
            (string-append
             "setsid sh -c 'sleep 30' < /dev/null > /dev/null 2>&1 &\n"
             "echo leftover > $out\n"))
           (drv (derivation store "ku-d-leftover" bash (list "-c" script)
                  #:sources (list bash))))
      (build-ok drv))))

;; (e) sweeps right after the build ends: several short builds back to back, each
;; triggering a post-build sweep immediately, exercising rapid lease reuse.
(record "e-rapid-sweeps"
  (guard (c (else (format #t "  rapid-sweeps error: ~a~%" c) #f))
    (let loop ((n 0) (ok #t))
      (if (>= n 6) ok
          (let* ((drv (derivation store (string-append "ku-e" (number->string n))
                        bash '("-c" "echo rapid > $out") #:sources (list bash))))
            (loop (+ n 1) (and ok (build-ok drv))))))))

;; (f) a sustained build with waves of workers, closer to the CI's ~21-minute
;; goonix package build (guild compile workers): several rounds, each forking a
;; batch of background workers that churn and exit, with the builder waiting on
;; each wave.  Exercises the sweep against a build that ran many processes over
;; time, not just a single short burst.
(record "f-sustained-waves"
  (guard (c (else (format #t "  sustained-waves error: ~a~%" c) #f))
    (let* ((script
            (string-append
             "for wave in 1 2 3 4 5; do\n"
             "  for i in 1 2 3 4 5 6 7 8 9 10; do\n"
             "    ( n=0; while [ $n -lt 300000 ]; do n=$((n+1)); done ) &\n"
             "  done\n"
             "  wait\n"
             "done\n"
             "echo sustained > $out\n"))
           (drv (derivation store "ku-f-sustained" bash (list "-c" script)
                  #:sources (list bash))))
      (build-ok drv))))

(close-connection store)
(let ((failed (filter (lambda (p) (not (cdr p))) results)))
  (format #t "SUMMARY: ~a/~a passed~%" (- (length results) (length failed)) (length results))
  (exit (if (null? failed) 0 1)))
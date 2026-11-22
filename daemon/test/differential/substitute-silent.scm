;;; goonix: substituter-wait must not freeze the daemon (reviewer point 1).
;;; The daemon is started with GUIX pointing at a fake `guix substitute --query'
;;; helper that stays SILENT for SILENT_SECONDS before each reply, and with a
;;; small RTS allocation area (-A) so the GC runs often.  One client triggers a
;;; substitute query, parking the daemon's receiveLine on the helper's pipes.
;;; While that helper is silent, a SECOND client runs a loop of cheap queries that
;;; allocate.  A correct daemon waits through the GHC IO manager: the GC can stop
;;; every capability, so the second client's loop finishes in well under
;;; SILENT_SECONDS.  A daemon waiting in an `unsafe' foreign select() holds its
;;; capability; the next GC needs every capability to stop and freezes the second
;;; client until the silent helper finally writes.  We measure the second client's
;;; elapsed time and require it to finish well before the helper replies.
(use-modules (guix store) (guix derivations) (ice-9 match) (ice-9 threads)
             (srfi srfi-19))

(define silent-seconds (string->number (or (getenv "SILENT_SECONDS") "8")))
;; The second client must finish well before the helper replies.  Use a fraction
;; of the silence as the budget: generous enough for a loaded machine, far below
;; the silence so a frozen daemon (which waits the whole silence) fails.
(define budget-seconds (/ silent-seconds 2))

(define (now) (current-time))
(define (elapsed-since start)
  (let ((d (time-difference (now) start)))
    (+ (time-second d) (/ (time-nanosecond d) 1e9))))

;; A derivation whose output is not in the store, so has-substitutes? must ask
;; the (silent) substituter.  The builder never runs: this is a query.
(define silent-store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options silent-store #:use-substitutes? #t #:offload? #f
                   #:substitute-urls '("file:///nonexistent-substitute-url"))
(define drv (derivation silent-store "substitute-silent" "/does-not-exist" '()))
(define out (derivation->output-path drv))

;; Client 1: trigger the silent-helper query in a background thread.  It parks
;; the daemon's receiveLine for SILENT_SECONDS.  We do not wait for it here.
(define query-thread
  (begin-thread
    (catch #t
      (lambda () (has-substitutes? silent-store out))
      (lambda (key . args) #f))))

;; Give client 1 time to reach the daemon and park receiveLine on the silent
;; helper before we start timing the second client.
(usleep 500000)

;; Client 2: a loop of cheap queries that allocate (each opens a fresh connection
;; and reads a result), forcing the GC to run.  Time the whole loop.
(define iterations (string->number (or (getenv "BUSY_ITERATIONS") "400")))
(define start (now))
(let loop ((i 0))
  (when (< i iterations)
    (let ((s (open-connection (getenv "GUIX_DAEMON_SOCKET"))))
      ;; valid-path? allocates a reply and exercises the store read path.
      (valid-path? s out)
      (close-connection s))
    (loop (+ i 1))))
(define busy-elapsed (elapsed-since start))

(format #t "substitute-silent: busy-client ~a iterations in ~,2fs (budget ~,2fs, silence ~as)~%"
        iterations busy-elapsed budget-seconds silent-seconds)

;; The busy client must finish well before the silent helper replies.  A frozen
;; daemon makes this loop wait the whole silence (>= silent-seconds), failing the
;; budget.  Check the measured RESULT, not only an exit code.
(if (< busy-elapsed budget-seconds)
    (begin
      (format #t "substitute-silent-wait: PASS (daemon kept serving during the silent helper)~%")
      (primitive-exit 0))
    (begin
      (format #t "substitute-silent-wait: FAIL (busy client took ~,2fs >= budget ~,2fs; daemon froze during the silent helper)~%"
              busy-elapsed budget-seconds)
      (primitive-exit 1)))
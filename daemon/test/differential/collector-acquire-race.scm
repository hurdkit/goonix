;; Collector acquire-ordering deadlock (reviewer follow-up to 3ad3c1caf78).
;;
;; withCollectorGCLock acquires the exclusive GC lock AND sets the own-collector
;; flag in ONE step under tempRootLock.  The test-only flag-delay hook widens the
;; acquire -> flag-set window to 1 s.  A collection runs in a thread; a NEW client
;; arrives during the delay and roots an item.  With the fix the client waits for
;; tempRootLock (held by the collector during acquire), then enters once the flag
;; is set and skips the GC lock; both finish and the root survives.  On the
;; pre-fix acquire (lock taken, flag set later, outside tempRootLock) the client
;; sees the flag unset, takes tempRootLock, and blocks on the GC read lock while
;; the collector's release waits for tempRootLock — deadlock (timeout).
(use-modules (guix store) (ice-9 textual-ports) (ice-9 threads)
             (ice-9 rdelim) (srfi srfi-1) (srfi srfi-11) (srfi srfi-34))

(define (assert condition message)
  (unless condition (error message)))

(define fixture (getenv "COL_FIXTURE"))
(define socket (getenv "COL_SOCKET"))

(define (marker name)
  (call-with-output-file (string-append fixture "/" name)
    (lambda (port) (display "done" port) (newline port))))

(define (wait-marker name)
  (let loop ()
    (unless (file-exists? (string-append fixture "/" name))
      (usleep 5000) (loop))))

(define a (open-connection socket))
(set-build-options a #:use-substitutes? #f #:offload? #f)
(define keeper (add-text-to-store a "acq-keeper" "kept by a permanent root"))
(add-permanent-root keeper)
(define dead-items
  (map (lambda (i)
         (add-text-to-store a (string-append "acq-dead-" (number->string i))
                            (string-append "dead " (number->string i))))
       (iota 20)))

;; A collection in a thread: acquires the GC lock, delays 1 s before setting the
;; flag (the hook), then collects.  A new client arrives during the delay.
(define collect-thread
  (call-with-new-thread
    (lambda ()
      (guard (c (#t (marker "collect-failed")))
        (collect-garbage a)
        (marker "collected")))))

;; Let the collection enter the acquire -> flag-set delay window, then a NEW
;; client roots an item.  With the fix this finishes; pre-fix it deadlocks.
(usleep 300000)
(define b (open-connection socket))
(set-build-options b #:use-substitutes? #f)
(define b-item (add-text-to-store b "acq-midroot" "rooted during the acquire delay"))
(add-temp-root b b-item)
(assert (valid-path? b b-item) "new client's item was not registered")
(marker "b-rooted")

(join-thread collect-thread)
(assert (not (file-exists? (string-append fixture "/collect-failed"))) "collection failed")
(wait-marker "b-rooted")

;; The new client's root survived the collection.
(assert (valid-path? a b-item) "new client's root became invalid")
(assert (file-exists? b-item) "new client's root lost its files")
(close-connection b)
(close-connection a)
(format #t "collector acquire-ordering race: PASS~%")
(force-output)
(primitive-exit 0)
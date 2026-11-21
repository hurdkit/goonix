;; Collector release-ordering race (reviewer follow-up to e9020d578b3).
;;
;; One Haskell daemon.  A collection runs in a thread (its ownCollector flag is
;; set while it holds gc.lock).  A NEW client opens a connection and roots an
;; item: it checks the flag, sees it set, skips the shared GC lock, and creates
;; its temporary-root file — the test-only delay widens that flag-check ->
;; file-creation window to 200ms.
;;
;; The fix clears the flag and releases gc.lock UNDER tempRootLock, which the
;; new client holds across the delay and file creation.  So the collection's
;; release cannot complete until the client's file exists; a collector in
;; another process that then takes gc.lock and enumerates temproots/ sees the
;; file and keeps the item.  We verify the ordering by collecting again after
;; the client has rooted: the item must survive (its root file existed before
;; any later enumeration).  With the pre-fix release the window could let a
;; later collector enumerate before the file exists and delete the item.
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
(define keeper (add-text-to-store a "race-keeper" "kept by a permanent root"))
(add-permanent-root keeper)
(define dead-items
  (map (lambda (i)
         (add-text-to-store a (string-append "race-dead-" (number->string i))
                            (string-append "dead " (number->string i))))
       (iota 20)))

;; A collection in a thread sets the ownCollector flag while it holds gc.lock.
(define collect-thread
  (call-with-new-thread
    (lambda ()
      (guard (c (#t (marker "collect-failed")))
        (collect-garbage a)
        (marker "collected")))))

;; A NEW client roots an item across the widened flag-check -> file-creation
;; window.  It skips the shared GC lock (the flag is set during the collection).
(define b (open-connection socket))
(set-build-options b #:use-substitutes? #f)
(define b-item (add-text-to-store b "race-midroot" "rooted across the release window"))
(add-temp-root b b-item)
(assert (valid-path? b b-item) "new client's item was not registered")
(marker "b-rooted")

(join-thread collect-thread)
(assert (not (file-exists? (string-append fixture "/collect-failed"))) "collection failed")
(wait-marker "b-rooted")

;; The new client's temporary-root file must exist once it has rooted: the
;; release ordering guarantees the file is created before the GC lock is freed.
(define temproots (string-append fixture "/var/temproots"))
(define root-files
  (let ((dir (opendir temproots)))
    (let loop ((acc '()))
      (let ((entry (readdir dir)))
        (if (eof-object? entry)
            (begin (closedir dir) acc)
            (loop (cons entry acc)))))))
(assert (any (lambda (f) (and (not (member f '("." "..")))
                              (file-exists? (string-append temproots "/" f))))
             root-files)
        "no temporary-root file exists after the new client rooted")

;; A second collection (flag set again) must keep the new client's root: its
;; file existed before this enumeration, so the ordering held.
(define deleted2
  (let-values (((deleted freed) (collect-garbage a)))
    deleted))
(assert (not (member b-item deleted2)) "release-ordering race: later collection deleted the new client's root")
(assert (valid-path? a b-item) "new client's root became invalid")
(assert (file-exists? b-item) "new client's root lost its files")
(assert (not (member keeper deleted2)) "permanent root was deleted")
(close-connection b)
(close-connection a)
(format #t "collector release-ordering race: PASS~%")
(force-output)
(primitive-exit 0)
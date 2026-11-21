;; Collector stage cross-process guard: a new client's first temporary root
;; blocks while an EXTERNAL process holds gc.lock exclusively.  The daemon under
;; test is not collecting (its ownCollector flag is clear), so creating the
;; temporary-root file must take the shared GC lock and wait for the holder.
(use-modules (guix store) (ice-9 textual-ports))

(define fixture (getenv "COL_FIXTURE"))
(define socket (getenv "COL_SOCKET"))

(define store (open-connection socket))
(set-build-options store #:use-substitutes? #f)
;; add-text-to-store appends a temporary root, which creates this connection's
;; temporary-root file.  With an external exclusive gc.lock holder this blocks
;; until the holder releases; the runner checks we have NOT reached the marker
;; while the holder is up, then that we do after it is released.
(define path (add-text-to-store store "col-xproc-item" "rooted after the external lock"))
(add-temp-root store path)
(call-with-output-file (string-append fixture "/client-rooted")
  (lambda (port) (display path port) (newline port)))
(close-connection store)
(format #t "external GC lock blocks new temporary root: PASS~%")
(force-output)
(primitive-exit 0)
;;; goonix: minimal client for the job-isolation smoke test.
;;;
;;; Runs INSIDE the committed CA-8 runner's namespace, against its own daemon,
;;; and does almost nothing: it proves the runner reached a working daemon with
;;; the PID namespace in place, in seconds rather than hours.  The isolation
;;; itself is asserted by the part script's PID_NS_CHECK (PID 1) and by
;;; goonix-ca6/pid-ns-check.sh's mutation regression; this file only has to give
;;; the runner a client that succeeds quickly.
(use-modules (guix store) (guix base32) (ice-9 format))

(let ((s (open-connection)))
  (format #t "ISOLATION_SMOKE: connected to the namespace daemon~%")
  (format #t "ISOLATION_SMOKE: store prefix ~a~%" (%store-prefix))
  ;; A trivial derivation-free query: no builds, no downloads, no substitutes.
  (format #t "ISOLATION_SMOKE: valid-path count probe ~a~%"
          (if (false-if-exception (valid-path? s (%store-prefix)))
              'yes 'no))
  (close-connection s)
  (format #t "ISOLATION_SMOKE OK~%"))
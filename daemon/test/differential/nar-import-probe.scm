;;; goonix: minimal add-to-store (NAR import) probe.  Args: SOCKET FILE
;;; The build/roots/watchdog stress clients hang; substitute/gc pass.  The hanging
;;; ones all call add-to-store (NAR import via readSocket); the passing ones do not.
;;; This isolates whether add-to-store hangs with the IO-manager socket fix.
(use-modules (guix store) (ice-9 match))
(define socket (cadr (command-line)))
(define file (caddr (command-line)))
(format #t "nar-import: connecting~%") (force-output)
(define s (open-connection socket))
(format #t "nar-import: adding ~a~%" file) (force-output)
(define p (add-to-store s "probe" #t "sha256" file))
(format #t "nar-import: added ~a~%" p) (force-output)
(close-connection s)
(format #t "nar-import: PASS~%")
(primitive-exit 0)
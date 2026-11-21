;;; GNU Guix --- Functional package management for GNU
;;; This file is part of GNU Guix and is distributed under GPL-3.0-or-later.

;; Read-only and disposable-store probes for inventory items 9.1, 9.6,
;; 9.7 and 9.9.  Run through build-aux/test-env with the recording proxy.
(use-modules (guix store) (guix derivations) (guix tests))

(define (attempt label thunk)
  (catch #t
    (lambda () (format #t "~a=~s~%" label (thunk)))
    (lambda args (format #t "~a-error=~s~%" label args))))

(define store (open-connection-for-tests))
(set-build-options store #:use-substitutes? #f #:verbosity 1
                   #:log-type 0 #:print-build-trace #t)
(format #t "handshake-completed=~s~%" (store-connection? store))

(let ((path (string-append (getenv "NIX_STORE_DIR")
                           "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-hs0-missing")))
  (attempt 'build-things-missing (lambda () (build-things store (list path))))
  (attempt 'ensure-path-missing (lambda () (ensure-path store path)))
  (attempt 'check-missing
           (lambda () (build-things store (list path) (build-mode check)))))

(let ((drv (build-expression->derivation
            store "hs0-trace"
            '(call-with-output-file %output
               (lambda (port) (display "trace" port))))))
  (attempt 'build-trace (lambda () (build-derivations store (list drv))))
  (format #t "trace-output=~s~%" (derivation->output-path drv)))

(close-connection store)

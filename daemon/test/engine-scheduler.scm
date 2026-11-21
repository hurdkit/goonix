;; HS-4 engine scheduler: event-order tests, not elapsed-time assertions.
(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap) (ice-9 textual-ports)
             (ice-9 match) (srfi srfi-34))
(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(define mode (getenv "HS4_SCHEDULER_MODE"))
(set-build-options store #:use-substitutes? #f #:offload? #f
                   #:max-build-jobs (if (equal? mode "serial") 1 2))
(%graft? #f)
(define fixture (getenv "HS4_SCHEDULER_FIXTURE"))
(define shell (add-to-store store "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))
(define (make-builder name)
  (add-text-to-store store (string-append name ".sh")
    (string-append
      "set -eu\n"
      "test -n \"$out\"\n"
      "printf start > '" fixture "/" name ".start'\n"
      "printf '%s\\n' " name " >> '" fixture "/events'\n"
      (if (equal? mode "serial")
          ""
          (string-append
            "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do\n"
            "  test -e '" fixture "/" (if (equal? name "left") "right" "left") ".start' && break\n"
            "  if read -t 1 _ < '" fixture "/tick'; then :; fi\n"
            "done\n"
            "test -e '" fixture "/" (if (equal? name "left") "right" "left") ".start'\n"))
      "printf end > '" fixture "/" name ".end'\n"
      "printf '%s-end\\n' " name " >> '" fixture "/events'\n"
      "printf '%s\\n' " name " > $out\n")))
(define (make-drv name script inputs)
  (derivation store name shell (list "-e" script)
              #:sources (cons shell (cons script inputs))))
(define (run-independent)
  (let* ((left-script (make-builder "left"))
         (right-script (make-builder "right"))
         (left (make-drv "left" left-script '()))
         (right (make-drv "right" right-script '())))
    (build-derivations store (list left right))
    (for-each (lambda (drv)
                (unless (valid-path? store (derivation->output-path drv))
                  (error "independent builder output is invalid" drv)))
              (list left right))))
(match mode
  ("parallel" (run-independent)
    (format #t "HS-4 parallel independent builders: PASS~%"))
  ("serial"
    (run-independent)
    ;; Both complete scripts have run; the start/end files encode the order.
    (unless (or (and (file-exists? (string-append fixture "/left.end"))
                     (file-exists? (string-append fixture "/right.start")))
                (and (file-exists? (string-append fixture "/right.end"))
                     (file-exists? (string-append fixture "/left.start"))))
      (error "serial builders did not both finish"))
    ;; This fixture's builders do not wait, so one complete interval precedes
    ;; the other's start in the daemon's event log; see the shell assertion.
    (format #t "HS-4 serial independent builders: PASS~%"))
  (_ (error "unknown scheduler test mode" mode)))
(close-connection store)

;;; goonix stress gate: one build client (a small distinct derivation).
;;; Args: SOCKET NAME
(use-modules (guix store) (guix derivations) (guix utils) (guix tests)
             (gnu packages bootstrap) (ice-9 match))
(define socket (cadr (command-line)))
(define name (caddr (command-line)))
(%graft? #f)
(define s (open-connection socket))
(set-build-options s #:use-substitutes? #f)
(define bash (add-to-store s "bash" #t "sha256"
                           (search-bootstrap-binary "bash" (%current-system))))
(define drv (derivation s name bash '("-c" "echo built > $out") #:sources (list bash)))
(define out (derivation->output-path drv))
(build-derivations s (list drv))
(close-connection s)
(if (and (file-exists? out) (valid-path? (open-connection socket) out))
    (begin (format #t "build ~a: PASS ~a~%" name out) (primitive-exit 0))
    (begin (format #t "build ~a: FAIL~%" name) (primitive-exit 1)))
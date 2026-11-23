;;; goonix stress gate: store verification afterwards.  The rooted output is still
;;; alive (the GC kept a rooted path) and appears among the store's roots.
;;; Args: SOCKET WORK-DIR
(use-modules (guix store) (ice-9 match))
(define socket (cadr (command-line)))
(define work (caddr (command-line)))
(define s (open-connection socket))
(define roots (find-roots s))
(define rooted-alive
  (any (lambda (pair)
         (let ((p (cdr pair)))
           (and (string-contains p "stress-rooted") (valid-path? s p))))
       roots))
(close-connection s)
(format #t "verify: rooted-alive=~a roots=~a~%" rooted-alive (length roots))
(if rooted-alive
    (begin (format #t "store-verify: PASS~%") (primitive-exit 0))
    (begin (format #t "store-verify: FAIL~%") (primitive-exit 1)))
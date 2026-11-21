(use-modules (guix store) (ice-9 textual-ports))

(define (assert condition message)
  (unless condition (error message)))

(with-store store
  (let* ((lines (call-with-input-file
                    (string-append (getenv "HS7_FIXTURE") "/restart-paths")
                  (lambda (port)
                    (let loop ((line (get-line port)) (result '()))
                      (if (eof-object? line) (reverse result)
                          (loop (get-line port) (cons line result)))))))
         (root (car lines)) (reference (cadr lines)) (dead (caddr lines))
         (link (string-append (getenv "HS7_FIXTURE") "/restart-root")))
    (assert (member (cons link root) (find-roots store)) "root lost across restart")
    (assert (member root (live-paths store)) "root not live across restart")
    (assert (member reference (live-paths store)) "reference not live across restart")
    (assert (not (valid-path? store dead)) "deleted path became valid across restart")
    (assert (not (file-exists? dead)) "deleted path reappeared across restart")
    (assert (verify-store store #:check-contents? #t) "restart verification failed")
    (assert (file-exists? root) "root deleted across restart")
    (assert (file-exists? reference) "reference deleted across restart"))
  (format #t "HS-7 restart preservation check: PASS\n"))

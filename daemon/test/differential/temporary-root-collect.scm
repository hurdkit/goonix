(use-modules (guix store) (srfi srfi-11) (ice-9 rdelim))

(define (assert condition message)
  (unless condition (error message)))

(unless (equal? (getenv "HS7_PHASE") "collect") (error "unexpected phase"))
(define store (open-connection (getenv "HS7_COLLECTOR_SOCKET")))
(define path (call-with-input-file (string-append (getenv "HS7_FIXTURE") "/held-path") read-line))
(assert (valid-path? store path) "other daemon cannot see registration")
(let-values (((deleted freed) (collect-garbage store)))
  (assert (not (member path deleted)) "live temporary root was deleted")
  (assert (valid-path? store path) "live temporary root became invalid")
  (assert (file-exists? path) "live temporary root lost its files"))
(format #t "HS-7 concurrent temporary-root preservation: PASS\n")

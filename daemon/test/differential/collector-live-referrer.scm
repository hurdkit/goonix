(use-modules (guix store) (guix tests) (srfi srfi-11) (srfi srfi-34) (ice-9 textual-ports))

(define (assert condition message)
  (unless condition (error message)))

(with-store store
  (let* ((dependency (add-text-to-store store "hs7-protected-dependency" "dependency"))
         (protected (add-text-to-store store "hs7-protected-referrer" "protected" (list dependency)))
         (link (string-append (getenv "HS7_ROOT") "/protected")))
    (symlink protected link)
    (add-indirect-root store link)
    (let ((refused?
           (guard (condition ((store-protocol-error? condition)
                             (let ((message (store-protocol-error-message condition)))
                               (format #t "refused: ~a\n" message)
                               (and (string-contains message "still alive") #t))))
             (format #t "accepted: ~s\n"
                     (call-with-values (lambda () (delete-paths store (list dependency))) list))
             #f)))
      (format #t "refused?=~s\n" refused?)
      (assert refused? "deleting a dependency with a live referrer was accepted")
      (assert (valid-path? store protected) "live referrer was unregistered")
      (assert (file-exists? protected) "live referrer was deleted")
      (assert (valid-path? store dependency) "dependency of live referrer was unregistered")
      (assert (file-exists? dependency) "dependency of live referrer was deleted")))

  (let* ((shared (add-text-to-store store "hs7-dead-target" "dead-target"))
         (dead-referrer (add-text-to-store store "hs7-dead-referrer" "dead" (list shared)))
         (live-referrer (add-text-to-store store "hs7-live-referrer" "live" (list shared)))
         (link (string-append (getenv "HS7_ROOT") "/live-referrer")))
    (symlink live-referrer link)
    (add-indirect-root store link)
    (let-values (((paths freed) (delete-paths store (list dead-referrer))))
      (assert (member dead-referrer paths) "dead referrer was not deleted")
      ;; C++ deletes the shared reference here even though the live referrer
      ;; keeps its own registration; do not invent transactional closure repair.
      (assert (not (member shared paths)) "shared dead dependency was not deleted")
      (assert (not (member live-referrer paths)) "live referrer of dead target was scheduled")
      (assert (valid-path? store live-referrer) "live referrer of dead target was unregistered")
      (assert (file-exists? live-referrer) "live referrer of dead target was deleted"))))

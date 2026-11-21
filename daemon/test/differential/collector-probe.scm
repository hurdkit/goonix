(use-modules (guix store) (guix derivations) (guix tests) (guix serialization) (guix hash)
             (guix base32) (gcrypt hash) (srfi srfi-1) (srfi srfi-11)
             (srfi srfi-34) (ice-9 threads) (ice-9 textual-ports)
             (rnrs io ports))

(define (assert condition message)
  (unless condition (error message)))

(define fixture (getenv "HS7_FIXTURE"))
(define (show label value)
  (format #t "~a: ~s\n" label (if (string? value)
                                  (basename value)
                                  value)))

(let ((store (open-connection (getenv "GUIX_DAEMON_SOCKET"))))
  (set-build-options store #:use-substitutes? #f)
  (let* ((reference (add-text-to-store store "hs7-diff-reference" "reference"))
         (root (add-text-to-store store "hs7-diff-root" "root" (list reference)))
         (dead (add-text-to-store store "hs7-diff-dead" "dead"))
         (link (string-append fixture "/root"))
         (profile-dir (string-append (getenv "GUIX_STATE_DIRECTORY") "/profiles")))
    (symlink root link)
    (add-indirect-root store link)
    (let* ((live (live-paths store))
           (dead-set (dead-paths store)))
      (assert (member root live) "root missing")
      (assert (member reference live) "reference missing")
      (assert (member dead dead-set) "dead missing"))
    ;; A nonexistent root is filtered by the C++ daemon.  It must not keep
    ;; unrelated dead items alive when supplied through the raw GC operation.
    (let* ((phantom (string-append (dirname root) "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-hs7-phantom"))
           (live-with-phantom
            (let-values (((paths freed obsolete)
                          ((module-ref (resolve-module '(guix store)) 'run-gc/direct)
                           store #:action 0 ; return-live
                                         #:to-delete (list phantom)
                                         #:min-freed (- (expt 2 64) 1)
                                         #:obsolete1 #f #:obsolete2 0
                                         #:obsolete3 0 #:obsolete4 0)))
              paths)))
      (assert (member root live-with-phantom) "real root lost beside nonexistent root")
      (assert (not (member dead live-with-phantom)) "nonexistent root retained dead"))
    (let-values (((paths freed) (collect-garbage store)))
      (assert (member dead paths) "dead not collected")
      (assert (> freed 0) "no bytes freed")
      (assert (not (file-exists? dead)) "dead file remains")
      (assert (not (valid-path? store dead)) "dead DB entry remains")
      (assert (file-exists? root) "root deleted")
      (assert (file-exists? reference) "reference deleted"))

    ;; Explicit deletion invalidates a dead referrer even after its reference
    ;; has reached max-freed, and does not delete a live referrer.
    (let* ((dependency (add-text-to-store store "hs7-diff-dependency" "dependency"))
           (dependent (add-text-to-store store "hs7-diff-dependent" "dependent" (list dependency)))
           (protected-ref (add-text-to-store store "hs7-diff-protected-ref" "protected-ref"))
           (protected (add-text-to-store store "hs7-diff-protected" "protected" (list protected-ref)))
           (protected-link (string-append fixture "/protected")))
      (symlink protected protected-link)
      (add-indirect-root store protected-link)
      (let ((limited
             (guard (condition
                     ;; GCLimitReached is not an Error in C++, so its daemon
                     ;; closes the socket instead of returning a GC result.
                     ((nar-error? condition) #t))
               (delete-paths store (list dependency) 1)
               #f)))
        (assert limited "bounded explicit deletion unexpectedly succeeded")
        (close-connection store)
        (set! store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
        (set-build-options store #:use-substitutes? #f)
        (assert (not (valid-path? store dependent)) "dependent DB entry remains")
        (assert (valid-path? store dependency) "dependency was deleted before referrer")
        (assert (file-exists? dependency) "dependency file was deleted before referrer")
        (assert (file-exists? protected) "live referrer was deleted")
        (assert (file-exists? protected-ref) "live referrer reference was deleted")))

    ;; Missing leaf and missing dependency with a live referrer.
    (let ((missing (add-text-to-store store "hs7-diff-missing" "missing")))
      (delete-file missing)
      (assert (verify-store store) "missing leaf was not invalidated")
      (assert (not (valid-path? store missing)) "missing leaf remains registered"))
    (let* ((needed (add-text-to-store store "hs7-diff-needed" "needed"))
           (user (add-text-to-store store "hs7-diff-user" "user" (list needed))))
      (delete-file needed)
      (assert (not (verify-store store)) "missing needed reference not reported")
      (assert (valid-path? store needed) "needed reference was invalidated despite live referrer")
      (assert (valid-path? store user) "live referrer lost")
      (assert (not (verify-store store #:repair? #t))
              "unrepairable missing reference was not reported")
      (assert (valid-path? store needed) "unrepairable reference was invalidated")

      ;; Do not carry intentional corruption into the clean concurrency check.
      (delete-paths store (list user needed))
      (assert (not (valid-path? store user)) "corrupted verifier fixture remains"))

    ;; Substitution repair uses fresh-store.sh's private substituter setup;
    ;; see repair-probe.scm and repair.sh.

    (let ((dangling (add-text-to-store store "hs7-diff-dangling"
                                       "dangling-symlink")))
      (delete-file dangling)
      (symlink "/definitely/not/a/store/target" dangling)
      (assert (eq? 'symlink (stat:type (lstat dangling)))
              "fixture is not a dangling symlink")
      (assert (not (file-exists? dangling)) "dangling fixture unexpectedly resolves")
      (assert (not (verify-store store #:check-contents? #t))
              "dangling symlink content change was not detected")
      (assert (valid-path? store dangling) "lstat verifier removed a symlink")
      (let-values (((paths freed) (collect-garbage store)))
        (assert (member dangling paths) "dangling store symlink not collected")
        (assert (not (valid-path? store dangling)) "dangling symlink still registered")
        (assert (not (file-exists? dangling)) "dangling symlink target was followed")
        (assert (not (file-exists? dangling)) "dangling symlink was not unlinked")))

    ;; Twelve genuinely distinct concurrent inputs.  Guile worker exceptions do
    ;; not propagate through join-thread, so record and re-raise them here.
    (let ((barrier (make-mutex))
          (condition (make-condition-variable))
          (lock (make-mutex))
          (failure #f)
          (paths '()))
      (define (worker thunk)
        (guard (c (#t (with-mutex lock (unless failure (set! failure c))))) (thunk)))
      (define (add-one index)
        (with-mutex barrier (wait-condition-variable condition barrier))
        (let ((connection (open-connection (getenv "GUIX_DAEMON_SOCKET"))))
          (let ((path (add-text-to-store connection
                                        (string-append "hs7-diff-concurrent-" (number->string index))
                                        (string-append "distinct-item-" (number->string index)))))
            (assert (valid-path? connection path) "new registration not visible")
            (close-connection connection)
            (with-mutex lock (set! paths (cons path paths))))))
      (let ((workers (map (lambda (index) (call-with-new-thread (lambda () (worker (lambda () (add-one index))))))
                          (iota 12)))
            (verifier (call-with-new-thread
                       (lambda ()
                         (worker (lambda ()
                                   (with-mutex barrier (broadcast-condition-variable condition))
                                   (assert (verify-store store #:check-contents? #t) "concurrent verify failed")))))))
        (for-each join-thread (cons verifier workers))
        (when failure (raise-exception failure)))
      (assert (= 12 (length paths)) "did not retain all concurrent paths")
      (for-each (lambda (path) (assert (valid-path? store path) "registered item disappeared")) paths))
    (show "final-live-count" (length (live-paths store)))
    (close-connection store)))
(format #t "HS-7 collector differential cases: PASS\n")

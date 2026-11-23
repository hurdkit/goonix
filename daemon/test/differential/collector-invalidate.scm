;; Compare the Collector's invalidate verdicts and the gcroot registration
;; against the REAL C++ daemon, over the socket, in one shared store path.
;;
;; What is diffed is the OBSERVABLE result, not just "did it throw":
;;   - the error MESSAGE text (C++ showPaths quotes each path as `path';
;;     an unquoted join differs),
;;   - which paths remain valid and on disk after each operation,
;;   - the root link name under gcroots/auto (SHA1 of the path STRING, so a
;;     relative path that C++ makes absolute first hashes differently),
;;   - find-roots' mapping.
(use-modules (guix store) (guix base32) (guix serialization)
             (ice-9 ftw) (srfi srfi-1) (srfi srfi-11) (srfi srfi-34)
             (rnrs bytevectors) (rnrs io ports))

(define fixture (getenv "COLLECT_FIXTURE"))
(define process-stderr
  (module-ref (resolve-module '(guix store)) 'process-stderr))

;; Report the daemon's message verbatim, minus the store prefix (identical in
;; both lanes anyway) so a wording difference is visible.
(define (attempt label thunk)
  (let ((result
         (guard (c (#t
                    (let ((msg (if (store-protocol-error? c)
                                   (store-protocol-error-message c)
                                   (with-output-to-string
                                     (lambda () (display c))))))
                      (string-append "ERROR " msg))))
           (let ((v (thunk)))
             (string-append "OK " (if (string? v) v (format #f "~s" v)))))))
    (format #t "~a ~a\n" label result)))

(define (valid-list store paths)
  (string-join (sort (map (lambda (p) (if (valid-path? store p) "1" "0"))
                          paths) string<?) ""))

(define (names paths)
  (string-join (sort (map basename paths) string<?) ","))

(let ((store (open-connection (getenv "GUIX_DAEMON_SOCKET"))))
  (set-build-options store #:use-substitutes? #f)

  ;; --- invalidatePathChecked: a dead referrer with TWO referrers, so the
  ;;     message lists more than one path and the quoting/order shows. ---
  (let* ((leaf (add-text-to-store store "inv-leaf" "leaf"))
         (userA (add-text-to-store store "inv-user-a" "user-a" (list leaf)))
         (userB (add-text-to-store store "inv-user-b" "user-b" (list leaf))))
    (attempt "in-use-two-referrers"
             (lambda () (delete-paths store (list leaf)) #t))
    (format #t "in-use-valid=~a\n" (valid-list store (list leaf userA userB)))
    ;; Deleting the referrers first, then the leaf, must succeed.
    (attempt "delete-referrers-then-leaf"
             (lambda () (delete-paths store (list userA userB leaf)) #t))
    (format #t "after-delete-valid=~a\n" (valid-list store (list leaf userA userB)))
    (format #t "after-delete-files=~a\n"
             (string-join (sort (map (lambda (p) (if (file-exists? p) "1" "0"))
                                   (list leaf userA userB)) string<?) "")))

  ;; --- a self-referencing path: the Refs schema needs the DeleteSelfRefs
  ;;     trigger, or the delete hits `on delete restrict'. ---
  (let* ((self (add-text-to-store store "self-ref" "self")))
    ;; A text item cannot refer to itself through add-text-to-store (its own
    ;; path is not known yet), so make the self-reference in the DB directly.
    (let ((db (string-append (getenv "GUIX_DATABASE_DIRECTORY") "/db.sqlite")))
      (system* (getenv "SQLITE3_BIN") db
               (format #f "insert into Refs(referrer,reference) select id,id from ValidPaths where path='~a';" self)))
    (attempt "delete-self-referencing"
             (lambda () (delete-paths store (list self)) #t))
    (format #t "self-valid=~a\n" (valid-list store (list self))))

  ;; --- deleting a path that is not registered at all ---
  (let ((ghost (string-append (getenv "NIX_STORE_DIR")
                              "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-never-registered")))
    (attempt "delete-unregistered"
             (lambda () (delete-paths store (list ghost)) #t)))

  ;; --- a LIVE path: the collector refuses, with its own wording ---
  (let* ((live (add-text-to-store store "live-item" "live"))
         (link (string-append fixture "/live-root")))
    (symlink live link)
    (add-indirect-root store link)
    (attempt "delete-live"
             (lambda () (delete-paths store (list live)) #t))
    (format #t "live-valid=~a\n" (valid-list store (list live)))

    ;; --- gcroot: the auto link name is SHA1 of the path STRING.  C++ runs
    ;;     absPath() on the wire value first; a relative path must therefore
    ;;     register the SAME root as its absolute form. ---
    (let* ((auto-dir (string-append (getenv "GUIX_STATE_DIRECTORY") "/gcroots/auto")))
      (attempt "add-indirect-absolute"
               (lambda () (add-indirect-root store link) #t))
      (format #t "auto-roots=~a\n"
              (string-join (sort (scandir auto-dir (lambda (n) (not (member n '("." "..")))))
                                 string<?) ","))
      ;; The root must actually protect the item through a collection.
      (let-values (((paths freed) (collect-garbage store)))
        (format #t "gc-kept-live=~a\n" (if (valid-path? store live) "1" "0")))
      ;; find-roots must map the auto link back to the store path.
      (let ((roots (find-roots store)))
        (format #t "find-roots-count=~a live-rooted=~a\n"
                (length roots)
                (if (any (lambda (r) (equal? (cdr r) live)) roots) "1" "0"))))

    ;; --- a second registration of the SAME link is idempotent ---
    (attempt "add-indirect-twice"
             (lambda () (add-indirect-root store link) (add-indirect-root store link) #t))

    ;; --- registering a link whose target is NOT in the store ---
    (let ((outside (string-append fixture "/outside-root")))
      (symlink "/etc/hostname" outside)
      (attempt "add-indirect-outside-store"
               (lambda () (add-indirect-root store outside) #t))
      (let ((auto-dir (string-append (getenv "GUIX_STATE_DIRECTORY") "/gcroots/auto")))
        (format #t "auto-count-after-outside=~a\n"
                (length (scandir auto-dir (lambda (n) (not (member n '("." ".."))))))))

    ;; --- a NON-CANONICAL link path.  C++ wopAddIndirectRoot runs absPath() on
    ;;     the wire value and addIndirectRoot hashes THAT, so a redundant "./"
    ;;     segment and a trailing slash must register the same auto root as the
    ;;     canonical path, not a second one. ---
    (let* ((rel-link (string-append fixture "/rel-root"))
           (auto-dir (string-append (getenv "GUIX_STATE_DIRECTORY") "/gcroots/auto"))
           (before (scandir auto-dir (lambda (n) (not (member n '("." "..")))))))
      (symlink live rel-link)
      (attempt "add-indirect-noncanonical"
               (lambda ()
                 (add-indirect-root store
                                    (string-append fixture "/./rel-root/")) #t))
      (let ((after (scandir auto-dir (lambda (n) (not (member n '("." "..")))))))
        (format #t "noncanonical-new-roots=~a\n"
                (string-join (sort (lset-difference equal? after before) string<?) ","))
        (format #t "noncanonical-protects=~a\n"
                (let-values (((paths freed) (collect-garbage store)))
                  (if (valid-path? store live) "1" "0")))))))
  (close-connection store))
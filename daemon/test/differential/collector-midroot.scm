;; Collector stage (DECISIONS.md point 3): a root registered by a NEW client
;; WHILE a collection runs keeps its item, and the new client does not wait for
;; the whole collection.
;;
;; One Haskell daemon.  A builder blocks on a marker so a collection started
;; during its build overlaps a window we control.  While the collection is
;; running, client B opens a NEW connection, registers an item and holds it as a
;; temporary root.  The collector re-reads the shared STM root announcements
;; before each deletion, so B's item is kept even though it was not in the live
;; set computed when the collection began.  B's connection completes promptly: a
;; new client no longer takes the shared GC lock for its whole connection.
(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap) (ice-9 textual-ports) (ice-9 threads)
             (ice-9 rdelim) (srfi srfi-1) (srfi srfi-11) (srfi srfi-34))

(define (assert condition message)
  (unless condition (error message)))

(define fixture (getenv "COL_FIXTURE"))
(define socket (getenv "COL_SOCKET"))

(define (marker name)
  (call-with-output-file (string-append fixture "/" name)
    (lambda (port) (display "done" port) (newline port))))

(define (wait-marker name)
  (let loop ()
    (unless (file-exists? (string-append fixture "/" name))
      (usleep 10000) (loop))))

(%graft? #f)
(define a (open-connection socket))
(set-build-options a #:use-substitutes? #f #:offload? #f)
(define shell (add-to-store a "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))

;; Seed dead items and a permanent keeper.
(define dead-items
  (map (lambda (i)
         (add-text-to-store a (string-append "col-dead-" (number->string i))
                            (string-append "dead payload " (number->string i))))
       (iota 40)))
(define keeper (add-text-to-store a "col-keeper" "kept by a permanent root"))
(add-permanent-root keeper)

;; A builder that blocks until released, so a collection started now overlaps a
;; window we control.  Its derivation and inputs are rooted by the running build.
(define script
  (add-text-to-store a "col-blocked-builder.sh"
    (string-append
      "printf running > '" fixture "/builder-started'\n"
      "while test ! -e '" fixture "/release-builder'; do\n"
      "  read -t 1 _ < '" fixture "/tick' || true\n"
      "done\n"
      "printf done > \"$out\"\n")))
(define drv (derivation a "col-blocked-build" shell (list "-e" script)
                        #:sources (list shell script)))
;; The build runs on its OWN connection: the Guix protocol is one operation at a
;; time per connection, so the collection below must not share it.
(define build-conn (open-connection socket))
(set-build-options build-conn #:use-substitutes? #f #:offload? #f)
(define build-thread
  (call-with-new-thread
    (lambda ()
      (guard (c (#t (marker "build-failed")))
        (build-derivations build-conn (list drv))
        (marker "build-done")))))
(wait-marker "builder-started")

;; Start a collection in a thread while the builder is blocked.  The collection
;; returns while the builder is still running (builds do not wait for it).
(define collect-thread
  (call-with-new-thread
    (lambda ()
      (guard (c (#t (call-with-output-file (string-append fixture "/collect-error")
                      (lambda (port) (format port "~s~%" c)))
                    (marker "collect-failed")))
        (let-values (((deleted freed) (collect-garbage a)))
          (call-with-output-file (string-append fixture "/deleted")
            (lambda (port) (for-each (lambda (p) (display p port) (newline port)) deleted)))
          (marker "collected"))))))

;; While the collection is running, a NEW client B registers an item and holds it
;; as a temporary root.  This must not block on the collection, and the item must
;; survive because the collector re-reads the STM announcements before deleting.
(define b (open-connection socket))
(set-build-options b #:use-substitutes? #f)
(define b-item (add-text-to-store b "col-midroot" "rooted during the collection"))
(add-temp-root b b-item)
(assert (valid-path? b b-item) "B's item was not registered")
(marker "b-rooted")

;; Let the collection finish, then release the builder.
(let loop ()
  (unless (or (file-exists? (string-append fixture "/collected"))
              (file-exists? (string-append fixture "/collect-failed")))
    (usleep 10000) (loop)))
(call-with-output-file (string-append fixture "/release-builder") (lambda (port) (display "release" port)))
(join-thread collect-thread)
(join-thread build-thread)
(assert (not (file-exists? (string-append fixture "/collect-failed"))) "collection failed")
(assert (not (file-exists? (string-append fixture "/build-failed"))) "build failed")

;; B's mid-collection root survived; the seeded dead items were collected.
(define deleted
  (call-with-input-file (string-append fixture "/deleted")
    (lambda (port)
      (let loop ((acc '()))
        (let ((line (read-line port)))
          (if (eof-object? line) acc (loop (cons line acc))))))))
(assert (not (member b-item deleted)) "mid-collection root was deleted")
(assert (valid-path? a b-item) "mid-collection root became invalid")
(assert (file-exists? b-item) "mid-collection root lost its files")
(assert (not (member keeper deleted)) "permanent root was deleted")
(for-each (lambda (p)
            (assert (member p deleted)
                    (string-append "dead item not collected: " p)))
          dead-items)
(close-connection b)
(close-connection build-conn)
(close-connection a)
(format #t "collector mid-collection root preservation: PASS~%")
(force-output)
(primitive-exit 0)
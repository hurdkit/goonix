;;; goonix: a valid store item survives a failed build that produced its content.
(use-modules (guix)
             (guix tests)
             (guix ca)
             (gnu packages bootstrap)
             (guix derivations)
             (srfi srfi-1)
             (srfi srfi-34)
             (srfi srfi-64)
             (ice-9 threads)
             (ice-9 textual-ports))

(test-begin "ca-existing-item")

(define store (open-connection-for-tests))
(%graft? #f)

(define bash
  (add-to-store store "bash" #t "sha256"
                (search-bootstrap-binary "bash" (%current-system))))

(define (fresh-name prefix)
  ;; A new name on every run: the test store outlives a run.
  (string-append prefix "-"
                 (number->string (random 1000000000
                                         (random-state-from-platform)))))

(define (read-all file)
  (call-with-input-file file get-string-all))

(define* (content-derivation name script
                             #:key (outputs '("out")) (sources '())
                             (variant "one"))
  ;; VARIANT only makes two derivations of the same name differ.
  (derivation store name bash (list "-c" script)
              #:sources (cons bash sources)
              #:outputs outputs
              #:addressing 'content
              #:env-vars `(("variant" . ,variant))))

(define (build-fails? drv)
  (guard (condition ((store-protocol-error? condition) #t))
    (build-derivations store (list drv))
    #f))

(define (intact? item)
  (and (valid-path? store item)
       (file-exists? item)
       (string=? "same" (read-all item))))

(define (existing-item name)
  ;; Build the item that the later, failing builds will produce again.
  (let ((drv (content-derivation name "printf same > \"$out\"")))
    (build-derivations store (list drv))
    (realised-output-path store drv "out")))

(test-assert "an existing item survives a later output that fails"
  (let* ((name (fresh-name "ca-existing-sibling"))
         (item (existing-item name))
         ;; "out" has the content of ITEM; "zzz" is never made.
         (drv  (content-derivation name "printf same > \"$out\""
                                   #:outputs '("out" "zzz")
                                   #:variant "two")))
    (and (intact? item)
         (build-fails? drv)
         (intact? item))))

(test-assert "an existing item survives a second round that differs"
  (let* ((name (fresh-name "ca-existing-rounds"))
         (item (existing-item name))
         ;; The first round sees ITEM and writes its content.  If the daemon
         ;; removes ITEM between the rounds, the second round differs.
         (drv  (content-derivation
                name
                (string-append "if [ -e " item " ]; then printf same > \"$out\"; "
                               "else printf other > \"$out\"; fi")
                #:sources (list item)
                #:variant "two")))
    (dynamic-wind
      (lambda () (set-build-options store #:rounds 2))
      (lambda ()
        (and (intact? item)
             ;; Both outcomes are acceptable for the build itself.
             (begin (build-fails? drv) #t)
             (intact? item)))
      (lambda () (set-build-options store #:rounds 1)))))

(test-assert "verify-store preserves items registered by another connection"
  (let* ((done? #f)
         (verify-connection (open-connection-for-tests))
         (verifier
          (call-with-new-thread
           (lambda ()
             (let loop ((rounds 0))
               (if done?
                   rounds
                   (begin
                     (verify-store verify-connection)
                     (loop (+ rounds 1))))))))
         (tag (number->string (random 1000000000
                                    (random-state-from-platform)))))
    (sleep 1)
    (let ((paths
           (map (lambda (index)
                  (add-text-to-store
                   store
                   (string-append "verify-race-" tag "-"
                                  (number->string index))
                   (string-append tag " " (number->string index))))
                (iota 3000))))
      (set! done? #t)
      (let ((rounds (join-thread verifier)))
        (close-connection verify-connection)
        (and (positive? rounds)
             (every (lambda (path) (valid-path? store path)) paths))))))

(close-connection store)
(test-end)

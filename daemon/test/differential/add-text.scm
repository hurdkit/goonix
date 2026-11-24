;; Compare addTextToStore against the REAL C++ daemon over the socket.
;;
;; C++ reads the references as a PathSet (std::set): DUPLICATES are collapsed
;; and the order is sorted BEFORE computeStorePathForText stuffs them into the
;; hash "type" string.  A port that keeps the wire list as it arrived computes a
;; different type, hence a different store path, for the same logical input.
;;
;; guix/store.scm's add-text-to-store passes a list, so duplicate/unsorted
;; reference lists are driven with RAW frames.
(use-modules (guix store) (guix base32) (guix serialization)
             (ice-9 ftw) (srfi srfi-1) (srfi srfi-11) (srfi srfi-34)
             (rnrs bytevectors) (rnrs io ports))

(define fixture (getenv "TEXT_FIXTURE"))
(define process-stderr
  (module-ref (resolve-module '(guix store)) 'process-stderr))

(define (attempt label thunk)
  (let ((result
         (guard (c (#t
                    (let ((msg (if (store-protocol-error? c)
                                   (store-protocol-error-message c)
                                   (with-output-to-string
                                     (lambda () (display c))))))
                      (string-append "ERROR " msg))))
           (let ((v (thunk)))
             (string-append "OK " (if (string? v) (basename v) (format #f "~s" v)))))))
    (format #t "~a ~a\n" label result)))

;; Raw wopAddTextToStore with an explicit reference LIST (order and duplicates
;; preserved on the wire).
(define (raw-add-text store name contents refs)
  (let ((port (store-connection-socket store)))
    (write-value integer 8 port)          ; wopAddTextToStore
    (write-value utf8-string name port)
    (write-value utf8-string contents port)
    (write-value integer (length refs) port)
    (for-each (lambda (r) (write-value utf8-string r port)) refs)
    (force-output port)
    (let loop ((done? (process-stderr store)))
      (or done? (loop (process-stderr store))))
    (read-value store-path port)))

(let ((store (open-connection (getenv "GUIX_DAEMON_SOCKET"))))
  (set-build-options store #:use-substitutes? #f)
  (let* ((refA (add-text-to-store store "txt-ref-a" "a"))
         (refB (add-text-to-store store "txt-ref-b" "b")))

    ;; Baseline: no references.
    (attempt "no-refs" (lambda () (raw-add-text store "txt-none" "body" '())))

    ;; One reference, twice on the wire.  C++ collapses to a set of one, so the
    ;; path must equal the single-reference case.
    (attempt "one-ref" (lambda () (raw-add-text store "txt-dup" "body" (list refA))))
    (attempt "dup-ref" (lambda () (raw-add-text store "txt-dup" "body" (list refA refA))))
    (attempt "trip-ref" (lambda () (raw-add-text store "txt-dup" "body" (list refA refA refA))))

    ;; Two references in BOTH orders: a set sorts, so both must agree.
    (attempt "two-refs-ab"
             (lambda () (raw-add-text store "txt-two" "body" (list refA refB))))
    (attempt "two-refs-ba"
             (lambda () (raw-add-text store "txt-two" "body" (list refB refA))))
    ;; ... and with a duplicate mixed in.
    (attempt "two-refs-baa"
             (lambda () (raw-add-text store "txt-two" "body" (list refB refA refA))))

    ;; The registered reference SET must also be deduplicated, not just the path.
    (let ((p (raw-add-text store "txt-query" "body" (list refA refA refB))))
      (format #t "query-refs=~a\n"
              (string-join (sort (map basename (references store p)) string<?) ",")))

    ;; An invalid name must be refused BEFORE anything is written.
    (attempt "bad-name" (lambda () (raw-add-text store ".dot" "body" '())))
    (attempt "slash-name" (lambda () (raw-add-text store "a/b" "body" '())))

    ;; A reference that is not a store path at all.
    (attempt "foreign-ref"
             (lambda () (raw-add-text store "txt-foreign" "body" (list "/etc/hostname")))))
  (close-connection store))
;;; goonix: the references registered for a content-addressed output.
(use-modules (guix)
             (guix tests)
             (guix ca)
             (gnu packages bootstrap)
             (guix derivations)
             (srfi srfi-64))

(test-begin "ca-references")

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

(define* (built-item name script #:key (addressing 'content))
  ;; Build a derivation whose builder is SCRIPT and return its output.  The
  ;; builder sees bash as "$dep".
  (let ((drv (derivation store name bash (list "-c" script)
                         #:sources (list bash)
                         #:addressing addressing
                         #:env-vars `(("dep" . ,bash)))))
    (build-derivations store (list drv))
    (if (eq? addressing 'input)
        (derivation->output-path drv)
        (realised-output-path store drv "out"))))

(define names-itself "printf '%s %s' \"$out\" \"$dep\" > \"$out\"")
(define names-input "printf '%s' \"$dep\" > \"$out\"")

(define (sorted lst) (sort lst string<?))

(test-equal "an input-addressed output that names itself refers to itself"
  ;; The behaviour that content addressing has to keep.
  #t
  (let ((item (built-item (fresh-name "ia-names-itself") names-itself
                          #:addressing 'input)))
    (equal? (sorted (references store item))
            (sorted (list item bash)))))

(test-equal "a content output that names itself refers to itself"
  #t
  (let ((item (built-item (fresh-name "ca-names-itself") names-itself)))
    (equal? (sorted (references store item))
            (sorted (list item bash)))))

(test-equal "a content output that names only an input refers only to it"
  #t
  (let ((item (built-item (fresh-name "ca-names-input") names-input)))
    (equal? (references store item) (list bash))))

(close-connection store)
(test-end)

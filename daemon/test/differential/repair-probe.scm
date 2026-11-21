(use-modules (guix store) (guix derivations) (guix tests)
             (ice-9 textual-ports))

(define (assert condition message)
  (unless condition (error message)))

(with-store store
  (set-build-options store #:use-substitutes? #t
                     #:substitute-urls (%test-substitute-urls))
  (let* ((repair-drv (derivation store "hs7-diff-repair" "/does-not-exist" '()))
         (corrupt (derivation->output-path repair-drv)))
    (with-derivation-substitute repair-drv "original"
      (ensure-path store corrupt)
      (chmod corrupt #o644)
      (call-with-output-file corrupt (lambda (port) (display "tampered" port)))
      (assert (not (verify-store store #:check-contents? #t))
              "modified content was accepted")
      (set-build-options store #:use-substitutes? #t
                         #:substitute-urls (%test-substitute-urls))
      (assert (verify-store store #:check-contents? #t #:repair? #t)
              "substitution repair failed")
      (assert (string=? (call-with-input-file corrupt get-string-all) "original")
              "repair did not restore content"))
    (delete-paths store (list corrupt))
    (assert (not (valid-path? store corrupt)) "repaired path could not be deleted")
    (let ((missing (add-text-to-store store "hs7-diff-repair-missing" "missing")))
      (delete-file missing)
      (assert (verify-store store #:repair? #t)
              "missing path without substitute was not reported")
      (assert (not (valid-path? store missing)) "unrepairable leaf stayed registered")))
  (format #t "HS-7 substitution repair: PASS\n"))

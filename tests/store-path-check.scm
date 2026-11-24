;;; goonix: the daemon computes every output path itself.
;;;
;;; Each test hands the daemon a derivation written by hand, whose output
;;; path is one the client chose, and looks at whether the daemon lets
;;; content appear there.
(use-modules (guix)
             (guix tests)
             (gnu packages bootstrap)
             (ice-9 match)
             (srfi srfi-34)
             (srfi srfi-64))

(test-begin "store-path-check")

(define store (open-connection-for-tests))

(define bash
  (add-to-store store "bash" #t "sha256"
                (search-bootstrap-binary "bash" (%current-system))))

(define (chosen-path name)
  ;; A well-formed store path that no rule of the daemon yields.
  (string-append (%store-prefix) "/" (make-string 32 #\a) "-" name))

(define (forged-derivation name marks)
  "Return the text of a derivation called NAME whose only output is
(chosen-path NAME), with MARKS, an alist, added to its environment."
  (let* ((target (chosen-path name))
         (env    (sort (cons `("out" . ,target) marks)
                       (lambda (a b) (string<? (car a) (car b))))))
    (format #f "Derive([(\"out\",\"~a\",\"\",\"\")],[],[\"~a\"],\"~a\",\"~a\",\
[\"-c\",\"echo forged > $out\"],[~a])"
            target bash (%current-system) bash
            (string-join (map (match-lambda
                                ((key . value)
                                 (format #f "(\"~a\",\"~a\")" key value)))
                              env)
                         ","))))

(define %state (random-state-from-platform))

(define (attempt base marks)
  "Register and build a forged derivation whose name starts with BASE.
Return 'refused when the daemon rejects the derivation itself, 'failed when
it accepts it and the build fails, 'poisoned when the chosen path is valid
afterwards, and 'elsewhere when the build succeeds without making it valid."
  (let* ((name   ;the test store outlives a run: take a new name each time
          (string-append base "-" (number->string (random (expt 2 62) %state)
                                                  16)))
         (target (chosen-path name))
         (text   (forged-derivation name marks)))
    (match (guard (c ((store-protocol-error? c) #f))
             (add-text-to-store store (string-append name ".drv")
                                text (list bash)))
      (#f 'refused)
      (file
       (let ((built? (guard (c ((store-protocol-error? c) #f))
                       (build-derivations store (list file)))))
         (cond ((valid-path? store target) 'poisoned)
               (built? 'elsewhere)
               (else 'failed)))))))

(test-equal "an unmarked derivation with a chosen output path is refused"
  'refused
  (attempt "forged-plain" '()))

(test-equal "marking it resolved does not get it accepted"
  'refused
  (attempt "forged-resolved" '(("goonixResolved" . "1"))))

(test-equal "nor does marking it content-addressed"
  'refused
  (attempt "forged-content" '(("goonixAddressing" . "content"))))

(test-equal "nor content-addressed and resolved"
  'refused
  (attempt "forged-content-resolved"
           '(("goonixAddressing" . "content") ("goonixResolved" . "1"))))

(test-equal "nor resolved-addressed"
  'refused
  (attempt "forged-resolved-addressed"
           '(("goonixAddressing" . "resolved"))))

(test-equal "nor resolved-addressed and resolved"
  'refused
  (attempt "forged-resolved-addressed-resolved"
           '(("goonixAddressing" . "resolved") ("goonixResolved" . "1"))))

(test-equal "nor an addressing the daemon does not know"
  'refused
  (attempt "forged-unknown" '(("goonixAddressing" . "input"))))

(test-end "store-path-check")

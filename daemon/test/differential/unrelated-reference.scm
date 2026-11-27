;; Regression: a built output refers only to its inputs' closure and its own
;; outputs, whatever other valid store paths its contents name (see
;; unrelated-reference.sh).  The output of each builder below contains the
;; file name of a derivation that is in the store but is no input of it.
(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap)
             (ice-9 textual-ports) (srfi srfi-1))

(define (assert condition message)
  (unless condition (error message)))

;; Each case is run and reported; the file fails if any of them failed.
(define failures '())
(define (check name thunk)
  (let ((ok (catch #t thunk
              (lambda (key . args)
                (format #t "  ~a: ~s ~s~%" name key args)
                #f))))
    (format #t "~a: ~a~%" name (if ok "pass" "FAIL"))
    (unless ok (set! failures (cons name failures)))))

(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options store #:use-substitutes? #f #:offload? #f)
(%graft? #f)

(define shell (add-to-store store "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))

;; A derivation that is never built: its file is valid, its output is not.
(define unbuilt-script
  (add-text-to-store store "unrelated-unbuilt-builder.sh"
                     "printf 'unbuilt\\n' > \"$out\"\n"))
(define unbuilt
  (derivation store "unrelated-unbuilt" shell (list "-e" unbuilt-script)
              #:sources (list shell unbuilt-script)))
(define unbuilt-file (derivation-file-name unbuilt))
(assert (valid-path? store unbuilt-file) "the unbuilt derivation is not in the store")
(assert (not (valid-path? store (derivation->output-path unbuilt)))
        "the unbuilt derivation's output is valid")

;; The derivation file name reaches the builder in the environment: the
;; derivation is not an input, so its file is not in the input closure.
(define naming-script
  (add-text-to-store store "unrelated-naming-builder.sh"
                     "printf '%s\\n' \"$unrelated\" > \"$out\"\n"))
(define (naming name addressing)
  (derivation store name shell (list "-e" naming-script)
              #:sources (list shell naming-script)
              #:addressing addressing
              #:env-vars `(("unrelated" . ,unbuilt-file))))

(define (built-output drv addressing)
  (build-derivations store (list drv))
  (if (eq? addressing 'input)
      (derivation->output-path drv)
      (realised-output-path store drv "out")))

;; An input-addressed output (C++ registerOutputs scans the paths of
;; inputsRealised, nix/libstore/build.cc).
(define input-addressed (naming "unrelated-input-addressed" 'input))
(define input-out (built-output input-addressed 'input))
(assert (string-contains (call-with-input-file input-out get-string-all)
                         unbuilt-file)
        "the input-addressed output does not name the derivation")
(check "input-addressed output"
       (lambda ()
         (not (member unbuilt-file (references store input-out)))))

;; A resolved-addressed output (C++ goonixInputPaths, nix/libstore/build-ca.cc).
(define resolved (naming "unrelated-resolved" 'resolved))
(check "resolved-addressed output"
       (lambda ()
         (let ((out (built-output resolved 'resolved)))
           (and (string-contains (call-with-input-file out get-string-all)
                                 unbuilt-file)
                (not (member unbuilt-file (references store out)))))))

;; The outputs of one build are among the paths, so an output refers to a
;; sibling.  "bin" names "out" and comes first in the order of the names: C++
;; registers the outputs together (registerValidPaths).
(define sibling-script
  (add-text-to-store store "unrelated-sibling-builder.sh"
                     "printf 'out\\n' > \"$out\"; printf '%s\\n' \"$out\" > \"$bin\"\n"))
(define sibling
  (derivation store "unrelated-sibling" shell (list "-e" sibling-script)
              #:sources (list shell sibling-script)
              #:outputs '("bin" "out")))
(check "output referring to a sibling output"
       (lambda ()
         (build-derivations store (list sibling))
         (equal? (list (derivation->output-path sibling "out"))
                 (references store (derivation->output-path sibling "bin")))))

;; The consequence that a CI store showed: a references graph over such an
;; output includes the outputs of every derivation in it, and the unbuilt
;; output is not valid.  The dependent must build.
(define graph-script
  (add-text-to-store store "unrelated-graph-builder.sh"
                     "read line < graph; printf 'graph\\n' > \"$out\"\n"))
(define graph
  (derivation store "unrelated-graph" shell (list "-e" graph-script)
              #:sources (list shell graph-script)
              #:inputs (list (derivation-input input-addressed))
              #:references-graphs `(("graph" . ,input-out))))
(check "references graph of the output"
       (lambda ()
         (build-derivations store (list graph))
         (valid-path? store (derivation->output-path graph))))

(close-connection store)
(if (null? failures)
    (display "unrelated store paths are no references: PASS\n")
    (begin
      (format #t "FAIL: ~{~a~^, ~}~%" (reverse failures))
      (exit 1)))

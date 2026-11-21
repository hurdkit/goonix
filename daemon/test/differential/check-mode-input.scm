;; Regression: --check of a derivation must not rebuild its (valid) inputs.
;; C++ builds inputs in normal mode unless repairing (DerivationGoal::
;; haveDerivation), so a valid input is done at once and only the top-level
;; derivation is rebuilt in check mode.  The input builder appends a marker each
;; time it runs; after a normal build of the top level followed by a check build,
;; the marker must show exactly one input build.  On an engine that passes the
;; caller's check mode to every job, the input is rebuilt (marker appears twice)
;; and this fails.
(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap) (ice-9 textual-ports) (srfi srfi-13) (srfi srfi-34))

(define (assert condition message)
  (unless condition (error message)))

(define fixture (getenv "HS7_FIXTURE"))
(define marker (string-append fixture "/input-builds"))
(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options store #:use-substitutes? #f #:offload? #f)
(%graft? #f)
(define shell (add-to-store store "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))
;; The input builder records each run by appending a line to the marker, then
;; writes a deterministic output.
(define input-script
  (add-text-to-store store "check-input-builder.sh"
    (string-append "printf 'built\\n' >> " marker "\n"
                   "printf 'input\\n' > \"$out\"\n")))
(define input-drv
  (derivation store "check-input" shell (list "-e" input-script)
              #:sources (list shell input-script)))
;; The top-level builder reads the input and writes a deterministic output.
;; Use only bash builtins (the build PATH is minimal; no external cat).
(define top-script
  (add-text-to-store store "check-top-builder.sh"
    "printf '%s\\n' \"$(< \"$input\")\" > \"$out\"\n"))
(define top-drv
  (derivation store "check-top" shell (list "-e" top-script)
              #:sources (list shell top-script)
              #:inputs (list (derivation-input input-drv))
              #:env-vars `(("input" . ,(derivation->output-path input-drv)))))
;; Normal build: the input runs once.
(build-derivations store (list top-drv))
(assert (valid-path? store (derivation->output-path top-drv))
        "top-level output not registered after normal build")
(define (marker-count)
  (if (file-exists? marker)
      (length (call-with-input-file marker
                (lambda (port)
                  (let loop ((line (get-line port)) (acc '()))
                    (if (eof-object? line) (reverse acc)
                        (loop (get-line port) (cons line acc)))))))
      0))
(assert (= 1 (marker-count)) "input did not run exactly once in the normal build")
;; Check build of the top level: the input is already valid, so it must NOT run
;; again.  Capture the trace and require a build-started line only for the top
;; level, never for the input.
(define trace
  (call-with-output-string
    (lambda (port)
      (parameterize ((current-build-output-port port))
        (build-derivations store (list top-drv) (build-mode check))))))
(assert (= 1 (marker-count))
        "check mode rebuilt the valid input derivation")
(assert (string-contains trace "@ build-succeeded")
        "check mode did not trace build-succeeded for the top level")
(when (string-contains trace (derivation-file-name input-drv))
  (error "check mode traced the input derivation (it was rebuilt)"))
(close-connection store)
(display "check-mode input-not-rebuilt: PASS\n")
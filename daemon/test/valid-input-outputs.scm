;; A requested input output is already valid even if its sibling is absent.
(use-modules (guix) (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap) (ice-9 textual-ports) (srfi srfi-34))
(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options store #:use-substitutes? #f #:offload? #f)
(%graft? #f)
(define shell (add-to-store store "bash" #t "sha256"
               (search-bootstrap-binary "bash" (%current-system))))
(define builder
  (add-text-to-store store "valid-input-builder"
    "echo out > $out; echo doc > $doc\n"))
(define input
  (derivation store "valid-input" shell (list "-e" builder)
              #:outputs '("out" "doc")
              #:sources (list builder shell)))
(define input-out (derivation->output-path input "out"))
(define input-doc (derivation->output-path input "doc"))
;; Build once, then retain only the requested output and its registration.
(build-derivations store (list input))
(delete-paths store (list input-doc))
;; Any unintended rebuild recreates and registers the sibling.
(when (valid-path? store input-doc)
  (error "fixture rebuilt the sibling output"))
(unless (and (valid-path? store input-out) (not (valid-path? store input-doc)))
  (error "failed to construct selected-output fixture"))
;; This would run the failing builder if the daemon checked every output.
(build-derivations store (list (cons (derivation-file-name input) "out")))
(when (valid-path? store input-doc)
  (error "direct requested build rebuilt the sibling output"))
(format #t "selected direct request: PASS~%") (force-output)
(define parent-builder
  (add-text-to-store store "valid-input-parent-builder" "echo parent > $out\n"))
(define parent
  (derivation store "valid-input-parent" shell (list "-e" parent-builder)
              #:sources (list parent-builder shell)
              #:inputs (list (derivation-input input '("out")))))
(format #t "parent derivation created: ~a~%" (derivation-file-name parent)) (force-output)
(build-derivations store (list parent))
(when (valid-path? store input-doc)
  (error "selected input dependency rebuilt its sibling output"))
(unless (valid-path? store (derivation->output-path parent))
  (error "parent output was not registered"))
(format #t "HS-6 valid requested output regression: PASS~%")
(close-connection store)

;; Mutation control: if the requested output itself is missing, the failing
;; builder must run. The successful assertions above therefore cannot be a
;; blanket "ignore every input" shortcut.
(define control (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options control #:use-substitutes? #f #:offload? #f)
(define control-shell (add-to-store control "bash" #t "sha256"
                       (search-bootstrap-binary "bash" (%current-system))))
(define control-builder
  (add-text-to-store control "valid-input-control-builder"
    "echo control-rebuilt >&2; exit 1; echo out > $out; echo doc > $doc\n"))
(define control-input
  (derivation control "valid-input-control" control-shell (list "-e" control-builder)
              #:outputs '("out" "doc") #:sources (list control-builder control-shell)))
(guard (condition
        ((store-protocol-error? condition)
         (unless (string-contains (store-protocol-error-message condition) "builder failed")
           (raise condition))
         (format #t "HS-6 missing requested output control: PASS~%")))
  (build-derivations control (list (cons (derivation-file-name control-input) "out")))
  (error "missing requested output did not attempt its failing build"))
(close-connection control)

;; An empty selection is not success: a nonexistent requested output must
;; not be silently removed from the output map.
(define invalid-output (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options invalid-output #:use-substitutes? #f #:offload? #f)
(guard (condition
        ((store-protocol-error? condition)
         (format #t "HS-4 nonexistent requested output: PASS~%")))
  (build-derivations invalid-output
    (list (cons (derivation-file-name input) "does-not-exist")))
  (error "nonexistent requested output was accepted"))
(close-connection invalid-output)

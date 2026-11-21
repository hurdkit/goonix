(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap) (ice-9 textual-ports) (srfi srfi-34))

(define (report-failure condition)
  (format (current-error-port) "temporary-root-builder client failed: ~s~%" condition)
  (force-output (current-error-port))
  (raise condition))

(guard (condition (else (report-failure condition)))

(define fixture (getenv "HS7_FIXTURE"))
(define store (open-connection (getenv "HS7_HOLDER_SOCKET")))
(set-build-options store #:use-substitutes? #f #:offload? #f)
(%graft? #f)
(define shell (add-to-store store "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))
(define input (add-text-to-store store "collector-live-input" "input retained by the running builder\n"))
;; The input derivation is built on another connection, which is then closed.
;; Its output is named by this builder, not by a reference in the parent's drv.
(define input-script
  (add-text-to-store store "collector-live-input-builder.sh"
    "printf 'retained\\n' > \"$out\"\n"))
(define input-drv
  (derivation store "collector-live-input-drv" shell (list "-e" input-script)
              #:sources (list shell input-script)))
(let ((input-client (open-connection (getenv "HS7_HOLDER_SOCKET"))))
  (set-build-options input-client #:use-substitutes? #f #:offload? #f)
  (build-derivations input-client (list input-drv))
  (unless (valid-path? input-client (derivation->output-path input-drv))
    (error "input derivation was not registered"))
  (unless (file-exists? (derivation->output-path input-drv))
    (error "input derivation output is absent before its client closes"))
  (close-connection input-client))
(call-with-output-file (string-append fixture "/input-output")
  (lambda (port) (display (derivation->output-path input-drv) port) (newline port)))
(define script
  (add-text-to-store store "collector-live-builder.sh"
    (string-append
      "set -eu\n"
      "printf '%s\\n' '" input "' > '" fixture "/builder-input'\n"
      "printf '%s\\n' \"$out\" > '" fixture "/builder-output'\n"
      "printf '%s\\n' \"$NIX_BUILD_TOP\" > '" fixture "/builder-work'\n"
      "read -r input_line < '" input "'\n"
      "printf '%s\\n' \"$input_line\" > '" fixture "/input-copy'\n"
      "printf running > '" fixture "/builder-started'\n"
      "while test ! -e '" fixture "/release-builder'; do\n"
      "  read -t 1 _ < '" fixture "/tick' || true\n"
      "done\n"
      "read -r dependent_input < '" (derivation->output-path input-drv) "'\n"
      "printf '%s\\n' \"$dependent_input\" > '" fixture "/dependent-input-copy'\n"
      "printf done > '" fixture "/builder-finished'\n"
      "printf '%s\\n' \"$input_line\" > \"$out\"\n")))
(define drv (derivation store "collector-live-build" shell
                        (list "-e" script)
                        #:sources (list shell script input)
                        #:inputs (list (derivation-input input-drv))))
(call-with-output-file (string-append fixture "/builder-drv")
  (lambda (port) (display (derivation-file-name drv) port) (newline port)))
(build-derivations store (list drv))
(unless (file-exists? (string-append fixture "/builder-finished"))
  (error "builder was not released"))
(unless (valid-path? store (derivation->output-path drv))
  (error "released builder did not register its output"))
(close-connection store)
(call-with-output-file (string-append fixture "/build-client-finished")
  (lambda (port) (display "done" port) (newline port)))
)

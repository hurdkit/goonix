;; Regression: a request for an unresolved content-addressed derivation
;; realises its inputs even when its own choice is valid (see
;; ca-collected-input.sh).  Each builder appends a line to a marker file, so
;; the test counts builder runs without reading the daemon's trace.
(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap)
             (ice-9 textual-ports) (srfi srfi-1))

(define (assert condition message)
  (unless condition (error message)))

(define fixture (getenv "CA_COLLECTED_INPUT_FIXTURE"))
(define marker (string-append fixture "/builder-runs"))
(define (runs of)
  (if (file-exists? marker)
      (count (lambda (line) (string=? line of))
             (string-split (call-with-input-file marker get-string-all)
                           #\newline))
      0))

(define (connect)
  (let ((store (open-connection (getenv "GUIX_DAEMON_SOCKET"))))
    (set-build-options store #:use-substitutes? #f #:offload? #f)
    store))

(%graft? #f)
(define store (connect))
(define shell (add-to-store store "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))
(define input-script
  (add-text-to-store store "ca-collected-input-builder.sh"
    (string-append "printf 'input\\n' >> " marker "\n"
                   "printf 'input\\n' > \"$out\"\n")))
(define input
  (derivation store "ca-collected-input" shell (list "-e" input-script)
              #:sources (list shell input-script)
              #:addressing 'content))
;; The dependent uses its input while it builds and keeps no reference to it,
;; so the input can be collected while the dependent stays valid.
(define top-script
  (add-text-to-store store "ca-collected-top-builder.sh"
    (string-append "printf 'top\\n' >> " marker "\n"
                   "if test -e \"$input\"; then printf 'present\\n' > \"$out\"; "
                   "else printf 'absent\\n' > \"$out\"; fi\n")))
(define top
  (derivation store "ca-collected-top" shell (list "-e" top-script)
              #:sources (list shell top-script)
              #:inputs (list (derivation-input input))
              #:addressing 'content
              #:env-vars `(("input" . ,(derivation->output-path input)))))

(build-derivations store (list top))
(define input-out (realised-output-path store input "out"))
(define top-out (realised-output-path store top "out"))
(assert (and (valid-path? store input-out) (valid-path? store top-out))
        "the first build did not realise both derivations")
(assert (equal? "present\n" (call-with-input-file top-out get-string-all))
        "the dependent did not see its input")
(assert (not (member input-out (references store top-out)))
        "the dependent refers to its build-time input")
(assert (and (= 1 (runs "input")) (= 1 (runs "top")))
        "the first build did not run each builder once")
(close-connection store)

;; Collect the input's output, with what refers to it (the dependent's
;; resolved derivation).  The dependent's output stays.
(define (collect-input)
  (let ((store (connect)))
    (delete-paths store (append (referrers store input-out) (list input-out)))
    (assert (and (not (valid-path? store input-out))
                 (valid-path? store top-out))
            "the input was not collected alone")
    (close-connection store)))

;; A normal request for the dependent: its output is valid and is not built
;; again; its input is realised again.
(collect-input)
(let ((store (connect)))
  (build-derivations store (list top))
  (assert (valid-path? store input-out)
          "a request for the dependent left its collected input unrealised")
  (assert (equal? input-out (realised-output-path store input "out"))
          "the input's realised path changed")
  (assert (equal? top-out (realised-output-path store top "out"))
          "the dependent's realised path changed")
  (assert (= 2 (runs "input")) "the collected input was not built again")
  (assert (= 1 (runs "top")) "the valid dependent was built again")
  (close-connection store))

;; A check of the dependent: the input is realised first, in normal mode, and
;; the dependent's builder runs for the check.
(collect-input)
(let ((store (connect)))
  (build-derivations store (list top) (build-mode check))
  (assert (valid-path? store input-out)
          "a check of the dependent left its collected input unrealised")
  (assert (= 3 (runs "input")) "the collected input was not built before the check")
  (assert (= 2 (runs "top")) "the check did not run the dependent's builder")
  (assert (equal? top-out (realised-output-path store top "out"))
          "the check changed the dependent's realised path")
  (close-connection store))

(display "collected input realised again: PASS\n")

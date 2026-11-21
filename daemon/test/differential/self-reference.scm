;; Regression: a self-referencing store output must report itself in
;; queryReferences, as the C++ daemon does.
;;
;; registerBuiltOutputs filtered the output's own path out of the scanned
;; references (filter (/= path) refs) before registering.  C++ keeps
;; self-references: scanForReferences searches the output's own path among the
;; candidates (build.cc allPaths inserts drv.outputs) and registerValidPaths
;; adds every reference including the path itself (local-store.cc, no
;; self-filter).  The grafts "grafted item is an indirect dependency" test
;; requires (references dep) to include dep itself (a `self -> $out` symlink).
;;
;; Build an output whose content is its own store path (so its NAR contains
;; its own hash), then assert its references include its own path.  On the
;; pre-fix daemon the self-reference is filtered out and this fails.
(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap) (srfi srfi-1))

(define (assert condition message)
  (unless condition (error message)))

(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options store #:use-substitutes? #f)
(%graft? #f)
(define shell (add-to-store store "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))
;; The builder writes the output path into the output file, so the output's
;; NAR contains its own hash (a self-reference).  Bash builtins only: the
;; build PATH has no mkdir/ln.
(define script
  (add-text-to-store store "self-ref-builder.sh"
    "printf '%s\\n' \"$out\" > \"$out\"\n"))
(define drv
  (derivation store "self-ref" shell (list "-e" script)
              #:sources (list shell script)))
(build-derivations store (list drv))
(define out (derivation->output-path drv))
(define refs (references store out))
(assert (member out refs)
        (string-append "self-reference missing from queryReferences: "
                       (format #f "~s" refs)))
(close-connection store)
(display "self-reference kept: PASS\n")
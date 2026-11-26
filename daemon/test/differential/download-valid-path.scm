;; Regression: a download job for a valid path asks no substituter.  The
;; client builds one derivation whose sources are all in the store, with
;; substitutes off; download-valid-path.sh then reads what the daemon started.
(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap))

(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options store #:use-substitutes? #f #:offload? #f)
(%graft? #f)
(define shell (add-to-store store "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))
(define script
  (add-text-to-store store "valid-source-builder.sh"
                     "printf 'built\\n' > \"$out\"\n"))
(define drv
  (derivation store "valid-source" shell (list "-e" script)
              #:sources (list shell script)))
(build-derivations store (list drv))
(unless (valid-path? store (derivation->output-path drv))
  (error "the output is not valid after the build"))
(close-connection store)
(display "valid-source build: done\n")

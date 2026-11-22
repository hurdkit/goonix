;; Build one output of NAR_MEM_MB MiB using bootstrap bash builtins only (no
;; network, no guile, no coreutils).  Only the NAR size matters, so the content
;; can be spaces: `printf '%*s' 1048576 ''` makes a 1 MiB blank chunk and the
;; loop writes MB of them.  The runner compares the daemon's peak memory across
;; two output sizes.
(use-modules (guix store) (guix derivations) (guix tests))

(let* ((mb (string->number (getenv "NAR_MEM_MB")))
       (store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
       (bash (add-to-store store "bash" #t "sha256"
                           (search-bootstrap-binary "bash" "x86_64-linux")))
       (script (add-text-to-store store "nar-mem-builder.sh"
                 "s=$(printf '%*s' 1048576 '')\nfor ((i=0; i<MB; i++)); do printf '%s' \"$s\"; done > \"$out\"\n"
                 (list)))
       (drv (derivation store "nar-mem" bash (list "-e" script)
                        #:inputs (list (list bash) (list script))
                        #:env-vars (list (cons "MB" (number->string mb))))))
  (build-derivations store (list drv))
  (format #t "nar-mem built mb=~s valid=~s narSize=~s\n"
          mb
          (valid-path? store (derivation->output-path drv))
          (path-info-nar-size (query-path-info store (derivation->output-path drv))))
  (close-connection store))
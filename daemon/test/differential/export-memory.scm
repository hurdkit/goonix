;; Build one output of EXPORT_MEM_MB MiB (bootstrap bash builtins only, no
;; network/guile/coreutils), then EXPORT it via the daemon's export-path RPC
;; (op 16), streaming the archive to a bytevector port.  The runner compares the
;; daemon's peak memory across two output sizes: a daemon that materialises the
;; whole NAR to export it pins ~output-size bytes; a streaming daemon (C++
;; HashAndWriteSink/TunnelSink, HS exportPathTo) stays bounded.
(use-modules (guix store) (guix derivations) (guix tests) (rnrs io ports) (rnrs bytevectors))

(let* ((mb (string->number (getenv "EXPORT_MEM_MB")))
       (store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
       (bash (add-to-store store "bash" #t "sha256"
                           (search-bootstrap-binary "bash" "x86_64-linux")))
       (script (add-text-to-store store "export-mem-builder.sh"
                 "s=$(printf '%*s' 1048576 '')\nfor ((i=0; i<MB; i++)); do printf '%s' \"$s\"; done > \"$out\"\n"
                 (list)))
       (drv (derivation store "export-mem" bash (list "-e" script)
                        #:inputs (list (list bash) (list script))
                        #:env-vars (list (cons "MB" (number->string mb)))))
       (out (derivation->output-path drv)))
  (build-derivations store (list drv))
  (format #t "export-mem built mb=~s valid=~s narSize=~s\n"
          mb (valid-path? store out)
          (path-info-nar-size (query-path-info store out)))
  ;; Export the large output through the daemon (op 16).  sign? #f avoids the
  ;; signing-key dependency; the NAR streaming path is identical either way.
  (let ((archive (call-with-bytevector-output-port
                   (lambda (port) (export-paths store (list out) port #:sign? #f)))))
    (format #t "export-mem exported mb=~s archive-bytes=~s daemon-alive=~s\n"
            mb (bytevector-length archive)
            (valid-path? store out)))
  (close-connection store))
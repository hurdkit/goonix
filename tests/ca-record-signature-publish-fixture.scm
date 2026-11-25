;;; goonix: make a signed record, then restore its raw advanced S-expression.
(use-modules (guix) (guix store) (guix derivations)
             (guix store database) (guix base64)
             (sqlite3) (rnrs bytevectors) (rnrs io ports) (ice-9 match))

(define store (open-connection))
(define shell (add-to-store store "legacy-signature-shell" #t "sha256"
                            (getenv "GOONIX_SHELL_SOURCE")))
(define drv (derivation store "legacy-signature" shell
                        '("-c" "printf legacy > \"$out\"")
                        #:sources (list shell) #:addressing 'content))
(build-derivations store (list drv))

(with-database (store-database-file) db
  (let ((query (sqlite-prepare db
                 "SELECT signature FROM GoonixBuildRecords
                  WHERE path = ? LIMIT 1;"))
        (output (realised-output-path store drv "out")))
    (sqlite-bind-arguments query output)
    (let ((row (sqlite-step query)))
      (unless row (error "fixture produced no signed record"))
      (let* ((raw (bytevector->string (base64-decode (vector-ref row 0))
                                      (make-transcoder (latin-1-codec))))
             (update (sqlite-prepare db
                       "UPDATE GoonixBuildRecords SET signature = ?
                        WHERE path = ?;")))
        (sqlite-bind-arguments update raw output)
        (sqlite-step update)
        (call-with-output-file (getenv "GOONIX_LEGACY_FIXTURE")
          (lambda (port)
            (set-port-encoding! port "ISO-8859-1")
            (write `((derivation ,(derivation-file-name drv))
                     (output ,output)
                     (raw-signature ,raw)) port)
            (newline port)))))))

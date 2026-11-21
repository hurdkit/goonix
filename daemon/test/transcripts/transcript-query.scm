(use-modules (guix store) (guix tests) (guix base32) (gcrypt hash) (ice-9 match)
             ((guix serialization) #:select (write-file-tree))
             (ice-9 textual-ports))
(let* ((s (open-connection (getenv "GUIX_DAEMON_SOCKET")))
       (path (string-append (%store-prefix) "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-transcript"))
       (nar (string-append (getenv "HS5_ROOT") "/transcript.nar")))
  (call-with-output-file nar
    (lambda (port)
      (write-file-tree "transcript" port
        #:file-type+size (lambda _ (values 'regular 11))
        #:file-port (lambda _ (open-input-string "transcript\n")))))
  (call-with-output-file
      (string-append (%substitute-directory) "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.narinfo")
    (lambda (port)
      (format port "StorePath: ~a\nURL: file://~a\nCompression: none\nNarSize: 1234\nNarHash: sha256:~a\nReferences: \nSystem: x86_64-linux\n"
              path nar (bytevector->nix-base32-string (file-sha256 nar)))))
  (set-build-options s #:use-substitutes? #t
                     #:substitute-urls (%test-substitute-urls))
  (match (command-line)
    ((program "have") (format #t "have=~s\n" (substitutable-paths s (list path))))
    ((program "info") (format #t "info=~s\n" (substitutable-path-info s (list path))))
    ((program "substitute") (ensure-path s path))
    (_ (format #t "unknown query\n") (exit 2)))
  (close-connection s))

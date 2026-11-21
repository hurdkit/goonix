;;; Restore cached downloads to this test's fresh store.
;;; Usage: pre-inst-env guile --no-auto-compile seed-restore.scm [SEED-DIR]
(use-modules (guix store) (guix tests) (ice-9 match) (ice-9 rdelim))
(define seed
  (match (command-line)
    ((_ directory) directory)
    (_ (string-append (getenv "HOME") "/.cache/goonix-test-seed"))))
(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(call-with-input-file (string-append seed "/index.tsv")
  (lambda (port)
    (let loop ((restored 0))
      (let ((line (read-line port)))
        (if (eof-object? line)
            (format #t "~a downloads restored from ~a~%" restored seed)
            (match (string-split line #\tab)
              ((name recursive "sha256" _ file)
               (add-to-store store name (string=? recursive "1") "sha256"
                             (string-append seed "/" file))
               (loop (+ restored 1)))
              (_ (loop restored))))))))
(close-connection store)

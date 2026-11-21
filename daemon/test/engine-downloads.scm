;; Opt-in download slots. The default control keeps C++ slot accounting.
(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap) (ice-9 rdelim) (ice-9 threads) (srfi srfi-34))
(define fixture (getenv "HS4_SCHEDULER_FIXTURE"))
(define separate? (equal? (getenv "HS4_DOWNLOAD_MODE") "separate"))
(define raw-set-options
  (hashq-ref (module-ref (resolve-module '(guix store)) '%client-stubs)
             'set-options))
(define (configure-downloads connection)
  (set-build-options connection #:use-substitutes? #t #:offload? #f
                     #:substitute-urls (%test-substitute-urls)
                     #:max-build-jobs 1)
  (when separate?
    (raw-set-options connection #:keep-failed? #f #:keep-going? #f #:fallback? #f
                     #:verbosity 0 #:offload? #f #:build-verbosity 0 #:log-type 0
                     #:print-build-trace #t #:use-substitutes? #t
                     #:settings
                     '(("build-separate-download-slots" . "true")
                       ("build-max-download-jobs" . "1")))))
(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(configure-downloads store)
(%graft? #f)
(define shell (add-to-store store "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))
(define mode-name (if separate? "separate" "default"))
(define waiting-script
  (add-text-to-store store (string-append "download-slot-waiting-" mode-name ".sh")
    (string-append
      "printf started > '" fixture "/builder-started-" mode-name "'\n"
      "while ! test -e '" fixture "/release-builder-" mode-name "'; do\n"
      "  read -t 1 _ < '" fixture "/tick' || true\n"
      "done\n"
      "printf done > $out\n")))
(define waiting
  (derivation store (string-append "download-slot-waiting-" mode-name) shell (list "-e" waiting-script)
              #:sources (list shell waiting-script)))
(define substituted-script
  (add-text-to-store store (string-append "download-slot-substituted-" mode-name ".sh") "printf substituted > $out\n"))
(define substituted
  (derivation store (string-append "download-slot-substituted-" mode-name) shell (list "-e" substituted-script)
              #:sources (list shell substituted-script)))
(with-derivation-substitute substituted "substituted\n"
  (let ((thread
          (begin-thread
            (let ((builder (open-connection (getenv "GUIX_DAEMON_SOCKET"))))
              (configure-downloads builder)
              (guard (condition
                      (else
                        (format #t "worker exception: ~s~%" condition)
                        (close-connection builder)
                        (raise condition)))
                (build-derivations builder (list waiting substituted)))
              (close-connection builder)))))
  (let loop ((n 0))
    (unless (file-exists? (string-append fixture "/builder-started-" mode-name))
      (when (> n 200) (error "independent builder did not start"))
      (usleep 10000)
      (loop (+ n 1))))
  (if separate?
      (let loop ((n 0))
        (unless (valid-path? store (derivation->output-path substituted))
          (when (> n 300) (error "download did not use its own slot"))
          (usleep 10000)
          (loop (+ n 1))))
      (begin
        (usleep 100000)
        (when (valid-path? store (derivation->output-path substituted))
          (error "default download escaped the occupied build slot"))))
  (call-with-output-file (string-append fixture "/release-builder-" mode-name)
    (lambda (port) (display "release\n" port)))
  (join-thread thread)))
(unless (valid-path? store (derivation->output-path substituted))
  (error "substituted output was not registered"))
(format #t "HS-4 download slots ~a: PASS~%"
        (if separate? "separate" "default shared"))
;; No substitute exists for this output. The attempted DownloadJob must let
;; discovery fall back to a local build rather than repeat itself.
(let* ((fallback-client (open-connection (getenv "GUIX_DAEMON_SOCKET")))
       (body (add-text-to-store fallback-client (string-append "download-fallback-" mode-name ".sh")
               "printf local > $out\n"))
       (local (derivation fallback-client (string-append "download-fallback-" mode-name)
                          shell (list "-e" body) #:sources (list shell body))))
  (configure-downloads fallback-client)
  (build-derivations fallback-client (list local))
  (unless (valid-path? fallback-client (derivation->output-path local))
    (error "missing substitute did not fall back to local build"))
  (close-connection fallback-client)
  (format #t "HS-4 missing substitute falls back ~a: PASS~%" mode-name))
(close-connection store)

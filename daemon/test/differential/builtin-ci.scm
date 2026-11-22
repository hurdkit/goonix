;;; goonix: builtin download / git-download under a CI-like daemon (HS-8
;;; switch-2 CI fix).  The daemon is started with no GUIX and PATH=/nonexistent;
;;; it must resolve the guix program via NIX_BIN_DIR / the configured bindir,
;;; not PATH.  This client (which has guix on PATH) builds a builtin:download
;;; fixed-output derivation from a local HTTP server (file:// is refused by
;;; perform-download's assert-non-local-urls, so a loopback URL stands in for
;;; the local file), and a builtin:git-download from a local repository served
;;; by git daemon.  It also builds a FAILING download and checks that
;;; `guix build --log-file' (log-file) finds its log.
(use-modules (guix store) (guix derivations) (guix hash) (guix config)
             (guix tests http) (guix tests git)
             ((guix git) #:select (with-repository))
             ((git oid) #:select (oid->string))
             ((git reference) #:select (reference-name->oid))
             ((gcrypt hash) #:prefix gcrypt:)
             (rnrs bytevectors) (ice-9 exceptions) (ice-9 match))

(define (build-ok drv)
  (build-derivations %store (list drv))
  (valid-path? %store (derivation->output-path drv)))

(define %store (open-connection))

;; 1. builtin:download from a local HTTP server, correct hash -> success.
(define download-ok
  (let ((text "goonix builtin download payload"))
    (with-http-server `((200 ,text))
      (let ((drv (derivation %store "ci-download" "builtin:download" '()
                   #:env-vars `(("url" . ,(object->string (%local-url))))
                   #:hash-algo 'sha256
                   #:hash (gcrypt:sha256 (string->utf8 text)))))
        (build-ok drv)))))

;; 2. builtin:git-download from a local repository (git daemon), correct hash.
(define git-download-ok
  (with-served-temporary-git-repository directory port
      '((add "a.txt" "goonix git payload")
        (commit "goonix"))
    (let* ((commit (with-repository directory repository
                     (oid->string (reference-name->oid repository "HEAD"))))
           (drv (derivation %store "ci-git-download" "builtin:git-download" '()
                  #:env-vars
                  `(("url" . ,(object->string
                                (string-append "git://localhost:"
                                               (number->string port) "/")))
                    ("commit" . ,commit))
                  #:hash-algo 'sha256
                  #:hash (file-hash* directory
                                     #:algorithm (gcrypt:hash-algorithm gcrypt:sha256)
                                     #:recursive? #t)
                  #:recursive? #t)))
      (build-ok drv))))

;; 3. A FAILING builtin:download (wrong hash) must leave a log that log-file
;;    (guix build --log-file) finds.
(define failing-log-found
  (with-http-server '((200 "some content"))
    (let ((drv (derivation %store "ci-failing" "builtin:download" '()
                 #:env-vars `(("url" . ,(object->string (%local-url))))
                 #:hash-algo 'sha256
                 #:hash (gcrypt:sha256 (string->utf8 "the wrong hash")))))
      (guard (c ((store-protocol-error? c) #t))
        (build-derivations %store (list drv))
        #f)
      (and (log-file %store (derivation-file-name drv)) #t))))

(format #t "download-ok=~a git-download-ok=~a failing-log-found=~a~%"
        download-ok git-download-ok failing-log-found)
(exit (if (and download-ok git-download-ok failing-log-found) 0 1))
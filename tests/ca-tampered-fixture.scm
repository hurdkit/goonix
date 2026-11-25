;;; goonix: one authorized server build, then a client receiving a tampered fact.
(use-modules (guix derivations) (guix store) (guix ca records)
             (rnrs io ports) (ice-9 match) (srfi srfi-1))

(define store (open-connection))
(define root (getenv "GOONIX_TAMPER_ROOT"))
(define shell (add-to-store store "tamper-shell" #t "sha256"
                            (getenv "GOONIX_SHELL_SOURCE")))
(define drv (derivation store "tampered-record" shell
                        '("-c" "printf 'server-result\n' > \"$out\"")
                        #:sources (list shell) #:addressing 'content
                        #:env-vars `(("cache" . ,(getenv "GOONIX_CACHE_URL")))))
(define (write-data file value)
  (call-with-output-file file (lambda (port) (write value port) (newline port))))
(match (command-line)
  ((_ "server")
   (build-derivations store (list drv))
   (write-data (string-append root "/server-result")
               `((drv ,(derivation-file-name drv))
                 (output ,(realised-output-path store drv "out")))))
  ((_ "client")
   (let ((server (call-with-input-file (string-append root "/server-result") read))
         (records-before (build-graph-records store (derivation-file-name drv))))
     (unless (null? records-before)
       (error "client started with graph records" records-before))
     (set-build-options store #:use-substitutes? #t #:verbosity 5
                        #:build-verbosity 5 #:print-build-trace #t
                        #:substitute-urls (list (getenv "GOONIX_TAMPER_URL")))
     (build-derivations store (list drv))
     (let ((actual (realised-output-path store drv "out"))
           (offered (cadr (assq 'output server))))
       ;; A refusal leaves the original content-addressed.  Refusal is proved
       ;; by the retained local record and absent offered path below.
       (unless (equal? "server-result\n"
                       (call-with-input-file actual get-string-all))
         (error "tampered graph did not fall back to the local build"))
       (let ((records-after (build-graph-records store (derivation-file-name drv))))
         (when (null? records-after)
           (error "local build record was not retained"))
         (when (any (lambda (record) (string=? (string-append offered "-tampered")
                                               (list-ref record 3)))
                    records-after)
           (error "tampered graph record was adopted" offered))
         (when (any (lambda (record) (not (string=? "local" (list-ref record 4))))
                    records-after)
           (error "non-local record survived graph refusal" records-after)))))))
(close-connection store)

;; A fixed-output builder that stays alive until the test kills its helper.
(use-modules (guix) (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap) (gcrypt hash)
             (ice-9 textual-ports) (rnrs bytevectors))
(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options store #:use-substitutes? #f #:use-build-hook? #f
                   #:print-build-trace #t)
(%graft? #f)
(define sleeper
  (add-to-store store "sleep" #t "sha256"
               (getenv "GOONIX_BOOTSTRAP_SLEEP")))
(define builder
  (add-text-to-store store "hs6-kill-builder.sh"
    (string-append "printf 'HS6 builder ready\\n'; exec '" sleeper "' 600\n")))
(call-with-output-file (string-append (getenv "HS6_KILL_FIXTURE") "/builder-path")
  (lambda (port) (display builder port)))
(define shell (add-to-store store "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))
(define drv
  (derivation store "hs6-helper-kill" shell (list "-e" builder)
              #:sources (list builder shell sleeper)
              #:hash (sha256 (string->utf8 "late\n")) #:hash-algo 'sha256))
(call-with-output-file (string-append (getenv "HS6_KILL_FIXTURE") "/derivation")
  (lambda (port) (display (derivation-file-name drv) port)))
;; The caller starts this process under timeout, so a failed kill is bounded.
(build-derivations store (list drv))
(error "fixed-output build unexpectedly completed")

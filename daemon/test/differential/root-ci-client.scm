;; PR #6 CI-like regression client.
;; Run inside the user namespace as a client WITHOUT GUIX_LOG_DIRECTORY.
;; Builds: builtin:download (file:// URI), builtin:git-download (local repo),
;; one ordinary derivation in the chroot, and a deliberately failing derivation
;; whose log `guix build --log-file` must find in /var/log/guix.
;;
;; Args: WORK-DIR GIT-REV PAYLOAD-HASH GIT-HASH
(use-modules (guix store) (guix derivations) (guix monads) (guix download)
             (guix git-download) (guix hash) (guix base32) (guix tests)
             (guix utils) (gnu packages bootstrap) (gcrypt hash) (rnrs io ports) (rnrs bytevectors)
             (ice-9 match) (ice-9 textual-ports) (srfi srfi-1) (srfi srfi-34))

(define work (cadr (command-line)))
(define gitrev (caddr (command-line)))
(define payload-hash-b32 (cadddr (command-line)))
(define git-hash-b32 (list-ref (command-line) 4))

(define store (open-connection))
(set-build-options store #:use-substitutes? #f)
(%graft? #f)

(define results '())
(define (record name ok)
  (set! results (cons (cons name ok) results))
  (format #t "~a: ~a~%" name (if ok "PASS" "FAIL")))

(define url-fetch* (store-lower url-fetch))

;; --- 1. builtin:download (file:// URI -> builtin:download fixed-output drv) ---
(record "builtin:download"
  (guard (c (else (format #t "  download error: ~a~%" c) #f))
    (let* ((url "http://127.0.0.1:18080/payload.txt")
           (hash (nix-base32-string->bytevector payload-hash-b32))
           (drv (url-fetch* store url 'sha256 hash #:guile %bootstrap-guile))
           (out (derivation->output-path drv)))
      (and (build-derivations store (list drv))
           (file-exists? out)
           (valid-path? store out)))))

;; --- 2. builtin:git-download (local git repo) ---
(record "builtin:git-download"
  (guard (c (else (format #t "  git-download error: ~a~%" c) #f))
    (let* ((repo "git://127.0.0.1:19418/")
           (hash (nix-base32-string->bytevector git-hash-b32))
           (drv (run-with-store store
                  (git-fetch (git-reference (url repo) (commit gitrev))
                             'sha256 hash "git-checkout"))))
      (and (build-derivations store (list drv))
           (file-exists? (derivation->output-path drv))
           (valid-path? store (derivation->output-path drv))))))

;; --- 3. ordinary derivation in the chroot (bootstrap bash) ---
(define bash (add-to-store store "bash" #t "sha256"
                           (search-bootstrap-binary "bash" (%current-system))))
(record "ordinary-chroot-build"
  (guard (c (else (format #t "  ordinary build error: ~a~%" c) #f))
    (let* ((drv (derivation store "pr6-ordinary" bash
                            '("-c" "echo built > $out")
                            #:sources (list bash)))
           (out (derivation->output-path drv)))
      (and (build-derivations store (list drv))
           (file-exists? out)
           (valid-path? store out)))))

;; --- 4. failing derivation; its log must be findable via --log-file ---
(define fail-drv (derivation store "pr6-fail" bash
                             '("-c" "echo failing >&2; exit 1")
                             #:sources (list bash)))
(define fail-log
  (guard (c ((store-protocol-error? c)
             (derivation-log-file (derivation-file-name fail-drv))))
    (build-derivations store (list fail-drv))
    #f))
(record "failing-build-log-found"
  (and (string? fail-log) (file-exists? fail-log)))
(format #t "  fail-log: ~a~%" fail-log)

(close-connection store)
(let ((failed (filter (lambda (p) (not (cdr p))) results)))
  (format #t "SUMMARY: ~a/~a passed~%" (- (length results) (length failed)) (length results))
  (exit (if (null? failed) 0 1)))
;; PR #6 CI-like regression client.
;; Run inside the user namespace as a client WITHOUT GUIX_LOG_DIRECTORY.
;; Builds: builtin:download (file:// URI), builtin:git-download (local repo),
;; one ordinary derivation in the chroot, a deliberately failing derivation
;; whose log `guix build --log-file` must find in /var/log/guix, and a
;; derivation whose transitive fixed-output source has been deleted (the store
;; keeps packages but not their sources, as CI restores it).
;;
;; Args: WORK-DIR GIT-REV PAYLOAD-HASH GIT-HASH
(use-modules (guix store) (guix derivations) (guix monads) (guix download)
             (guix git-download) (guix hash) (guix base32) (guix tests)
             (guix utils) (gnu packages bootstrap) (gcrypt hash) (rnrs io ports) (rnrs bytevectors)
             (ice-9 match) (ice-9 textual-ports) (ice-9 string-fun) (srfi srfi-1) (srfi srfi-34))

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

;; --- 5. a transitive fixed-output SOURCE need not be valid (PR #6 CI blocker) ---
;; A depends on B; B depends on a fixed-output source C.  Build B, delete C's
;; output (the store keeps packages but not their sources, as CI restores it),
;; then build A.  A must succeed: the chroot needs only the runtime closure of
;; A's direct inputs (B), never B's own build-time inputs (C).  C++ inputsRealised
;; never recurses into an input derivation's inputs.
(record "transitive-source-missing"
  (guard (c (else (format #t "  transitive-source error: ~a~%" c) #f))
    (let* ((c-content (string->utf8 "pr6 ci source payload\n"))
           (c-script (add-text-to-store store "pr6-c-builder.sh"
                       "printf \"pr6 ci source payload\\n\" > $out\n" (list)))
           (c (derivation store "pr6-ci-source" bash (list "-e" c-script)
                          #:inputs (list (list bash) (list c-script))
                          #:hash-algo 'sha256 #:hash (sha256 c-content)))
           (c-out (derivation->output-path c))
           (b-script (add-text-to-store store "pr6-b-builder.sh"
                       "printf \"hello-B\\n\" > $out\n" (list)))
           (b (derivation store "pr6-ci-b" bash (list "-e" b-script)
                          #:inputs (list (derivation-input c) (list bash) (list b-script))))
           (b-out (derivation->output-path b))
           (a-script (add-text-to-store store "pr6-a-builder.sh"
                       (string-append "read -r line < " b-out "\n"
                                      "printf \"%s-A\\n\" \"$line\" > $out\n") (list)))
           (a (derivation store "pr6-ci-a" bash (list "-e" a-script)
                          #:inputs (list (derivation-input b) (list bash) (list a-script))))
           (a-out (derivation->output-path a)))
      (build-derivations store (list b))
      (delete-paths store (list c-out))
      (and (not (valid-path? store c-out))
           (valid-path? store b-out)
           (build-derivations store (list a))
           (valid-path? store a-out)))))

;; --- 6. the chroot holds the runtime closure of the DIRECT inputs only ---
;; With every path present, A's builder lists the chroot store: B's output (a
;; direct input A references) must be there; C's output (B's own build-time
;; input, not in A's runtime closure) must NOT be there.  The recursive
;; derivationInputs leaks C (and every transitive build-time source) into the
;; chroot; C++ inputsRealised computeFSClosures only direct selected outputs.
(record "chroot-closure-no-transitive-source"
  (guard (c (else (format #t "  chroot-closure error: ~a~%" c) #f))
    (let* ((c-content (string->utf8 "pr6 closure source payload\n"))
           (c-script (add-text-to-store store "pr6-c2-builder.sh"
                       "printf \"pr6 closure source payload\\n\" > $out\n" (list)))
           (c (derivation store "pr6-ci2-source" bash (list "-e" c-script)
                          #:inputs (list (list bash) (list c-script))
                          #:hash-algo 'sha256 #:hash (sha256 c-content)))
           (c-out (derivation->output-path c))
           (b-script (add-text-to-store store "pr6-b2-builder.sh"
                       "printf \"hello-B\\n\" > $out\n" (list)))
           (b (derivation store "pr6-ci2-b" bash (list "-e" b-script)
                          #:inputs (list (derivation-input c) (list bash) (list b-script))))
           (b-out (derivation->output-path b))
           (a-script (add-text-to-store store "pr6-a2-builder.sh"
                       (string-append "read -r line < " b-out "\n"
                                      "for p in \"$NIX_STORE\"/*; do\n"
                                      "  printf \"%s\\n\" \"${p##*/}\"\n"
                                      "done > $out\n") (list)))
           (a (derivation store "pr6-ci2-a" bash (list "-e" a-script)
                          #:inputs (list (derivation-input b) (list bash) (list a-script))))
           (a-out (derivation->output-path a)))
      (build-derivations store (list b))
      (build-derivations store (list a))
      (let* ((listing (call-with-input-file a-out get-string-all))
             (c-base (basename c-out))
             (b-base (basename b-out)))
        (format #t "  chroot has B=~s C=~s~%"
                (string-contains listing b-base) (string-contains listing c-base))
        (and (string-contains listing b-base)
             (not (string-contains listing c-base)))))))

(close-connection store)
(let ((failed (filter (lambda (p) (not (cdr p))) results)))
  (format #t "SUMMARY: ~a/~a passed~%" (- (length results) (length failed)) (length results))
  (exit (if (null? failed) 0 1)))
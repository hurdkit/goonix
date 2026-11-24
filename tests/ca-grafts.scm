;;; goonix: CA-6 gate — grafts as content-addressed derivations.
;;;
;;; A graft that changes nothing yields the original path; a real
;;; replacement yields a different path and rewrites the reference.  The
;;; graft of a content-addressed derivation writes its own output at a
;;; self-token; (guix ca build graft) applies it through upstream's rewriter
;;; in two passes, and the daemon finalises the token to the content address.
;;; An input-addressed graft derivation is exactly upstream's.
(use-modules (guix)
             (guix tests)
             (guix grafts)
             (guix gexp)
             (guix ca)
             (guix ca graft)
             (guix ca policy)
             (guix derivations)
             (guix monads)
             (guix build-system trivial)
             (gnu packages bootstrap)
             (ice-9 match)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "ca-grafts")

(define store (open-connection-for-tests))
(%graft? #f)
(%graft-with-utf8-locale? #f)

(define guile-drv (package-derivation store %bootstrap-guile))
(build-derivations store (list guile-drv))

(define (fresh-name prefix)
  (string-append prefix "-"
                 (number->string (random 1000000000
                                         (random-state-from-platform)))))

(define (realised drv) (realised-output-path store drv "out"))
(define (read-all file) (call-with-input-file file get-string-all))

;; A content-addressed derivation whose output is TEXT.
(define (plain-drv name text)
  (run-with-store store
    (gexp->derivation name
      #~(call-with-output-file #$output (lambda (p) (display #$text p)))
      #:addressing 'content
      #:guile-for-build guile-drv)))

;; A content-addressed derivation whose output references DEP-PATH.
(define (ref-drv name dep-path text)
  (run-with-store store
    (gexp->derivation name
      #~(call-with-output-file #$output
          (lambda (p) (format p "~a/~a" #$dep-path #$text)))
      #:addressing 'content
      #:guile-for-build guile-drv)))

;; Graft the DEP reference inside ORIG: origin DEP, replacement REPL.
(define (graft-dep orig dep repl)
  (run-with-store store
    (graft-derivation/shallow orig
      (list (graft (origin dep) (replacement repl)))
      #:guile guile-drv)))

;; The gate runs under mixed policy, the plan's first policy: the graft is
;; content-addressed (its inputs are), while the graft's module-import
;; compilation stays input-addressed.
(parameterize ((%package-addressing-policy 'mixed))
  (let* ((dep-name  (fresh-name "ca-graft-dep"))
         (orig-name (fresh-name "ca-graft-orig"))
         (dep       (plain-drv dep-name "DEP"))
         (_         (build-derivations store (list dep)))
         (dep-path  (realised dep))
         (orig      (ref-drv orig-name dep-path "hello"))
         (_         (build-derivations store (list orig)))
         (orig-path (realised orig)))

    (test-equal "a graft that changes nothing yields the original path"
      orig-path
      (let* ((noop    (plain-drv dep-name "DEP"))
             (_       (build-derivations store (list noop)))
             (grafted (graft-dep orig dep noop))
             (_       (build-derivations store (list grafted))))
        (realised grafted)))

    (test-assert "a real replacement yields a different path and rewrites the reference"
      (let* ((real     (plain-drv dep-name "OTHER"))
             (_        (build-derivations store (list real)))
             (real-path (realised real))
             (grafted  (graft-dep orig dep real))
             (_        (build-derivations store (list grafted)))
             (path     (realised grafted)))
        (and (not (string=? orig-path path))
             ;; The dep reference is rewritten to the replacement's path;
             ;; orig's own text ("hello") is preserved.
             (string=? (string-append real-path "/hello")
                       (read-all path)))))))

;;; An input-addressed graft derivation is exactly upstream's: the two
;;; goonix helpers return the module list unchanged and the plain 'graft'
;;; symbol, so the builder text and the module list — and hence the
;;; derivation — are upstream's.
(let* ((ia-name (fresh-name "ca-graft-ia"))
       (ia-drv  (run-with-store store
                  (gexp->derivation ia-name
                    #~(call-with-output-file #$output
                        (lambda (p) (display "IA" p)))
                    #:addressing 'input
                    #:guile-for-build guile-drv)))
       (_       (build-derivations store (list ia-drv)))
       (base-modules '((guix build graft) (guix build utils)
                       (guix build debug-link) (guix elf))))
  (test-assert "an input-addressed target is not a self-token"
    (not (token-store-path? (derivation->output-path ia-drv))))
  (test-equal "the graft module list is unchanged for an input-addressed target"
    base-modules
    (goonix-graft-modules ia-drv base-modules))
  (test-eq "the graft procedure is the plain symbol for an input-addressed target"
    'graft
    (goonix-graft-procedure ia-drv))
  (test-assert "an input-addressed graft derivation has no CA addressing marker"
    (let* ((repl    (run-with-store store
                      (gexp->derivation ia-name
                        #~(call-with-output-file #$output
                            (lambda (p) (display "REPL" p)))
                        #:addressing 'input
                        #:guile-for-build guile-drv)))
           (_       (build-derivations store (list repl)))
           (grafted (graft-derivation store ia-drv
                      (list (graft (origin ia-drv) (replacement repl)))
                      #:guile guile-drv)))
      (not (assoc-ref (derivation-builder-environment-vars grafted)
                      "goonixAddressing")))))

;;; Adoption forces a graft of an input-addressed derivation content-addressed:
;;; under %graft-content-addressed? the helpers select the CA module and the
;;; graft derivation carries the content marker and loads (guix ca build graft).
(let* ((ia-name (fresh-name "ca-graft-adopt"))
       (ia-drv  (run-with-store store
                  (gexp->derivation ia-name
                    #~(call-with-output-file #$output
                        (lambda (p) (display "IA" p)))
                    #:addressing 'input
                    #:guile-for-build guile-drv)))
       (_       (build-derivations store (list ia-drv)))
       (repl    (run-with-store store
                  (gexp->derivation ia-name
                    #~(call-with-output-file #$output
                        (lambda (p) (display "REPL" p)))
                    #:addressing 'input
                    #:guile-for-build guile-drv)))
       (_       (build-derivations store (list repl)))
       (base-modules '((guix build graft) (guix build utils)
                       (guix build debug-link) (guix elf))))
  (parameterize ((%graft-content-addressed? #t))
    (test-equal "forced CA graft imports the content-addressed graft module"
      (append base-modules '((guix ca build graft)))
      (goonix-graft-modules ia-drv base-modules))
    (test-eq "forced CA graft calls graft/content-addressed"
      'graft/content-addressed
      (goonix-graft-procedure ia-drv))
    (test-equal "forced CA graft loads the module in its builder"
      '((use-modules (guix ca build graft)))
      (goonix-graft-load ia-drv))
    (test-assert "a forced CA graft of an input-addressed derivation is content-addressed"
      (let ((grafted (run-with-store store
                       (graft-derivation/shallow ia-drv
                         (list (graft (origin ia-drv) (replacement repl)))
                         #:guile guile-drv))))
        (and (equal? "content"
                     (assoc-ref (derivation-builder-environment-vars grafted)
                                "goonixAddressing"))
             ;; The builder text loads the CA module and calls the two-pass
             ;; procedure, and the graft builds to a content address.  On the
             ;; host the output path is a placeholder; the realised path is a
             ;; nix-base32 content address, not a token.
             (let ((builder (any (match-lambda
                                   ((key . value)
                                    (and (string-prefix? "__file:" key)
                                         value)))
                                 (derivation-builder-environment-vars grafted))))
               (build-derivations store (list grafted))
               (and (string-contains (or builder "") "(guix ca build graft)")
                    (placeholder-path? (derivation->output-path grafted))
                    (not (token-store-path?
                           (realised-output-path store grafted "out"))))))))))

(test-group "a graft over an unrealised reserved output does not query it"
  ;; A resolved or opaque package lowered under 'content has PLACEHOLDER
  ;; outputs until the daemon finalises them.  Computing its graft used to
  ;; call non-self-references, which asked the daemon for the references of
  ;; those placeholders; the store error made upstream's fallback try to
  ;; BUILD the derivation, sending the placeholder to the daemon, which
  ;; refuses reserved paths (assertNotReserved) and DROPS the connection.
  ;; The goonix hook must skip reserved outputs when READING, and realise
  ;; DRV by its .drv name when references are needed.  Before the fix this
  ;; group died with SIGPIPE (the daemon dropped the connection); after it,
  ;; the graft is computed and the connection is still usable.
  (define (content-package name)
    (package
      (name name)
      (version "1")
      (source #f)
      (build-system trivial-build-system)
      (arguments
       (list #:guile %bootstrap-guile
             #:builder #~(call-with-output-file #$output
                           (lambda (p) (display "PAYLOAD" p)))))
      (synopsis "CA graft placeholder test")
      (description "CA graft placeholder test")
      (home-page #f)
      (license #f)))
  (let* ((pkg (content-package (fresh-name "ca-graft-unrealised")))
         (drv (parameterize ((%package-addressing-policy 'content))
                (package-derivation store pkg))))
    (test-assert "the package's output is an unrealised placeholder"
      (and (placeholder-path? (derivation->output-path drv))
           (not (valid-path? store (derivation->output-path drv)))))
    (test-assert "the goonix hook reports the reserved output"
      (and (pair? (goonix-unrealised-outputs drv (derivation-output-names drv)))
           (not (goonix-unrealised-outputs
                 drv '()))))
    (test-assert "reading references realises DRV rather than querying a placeholder"
      ;; The helper builds DRV by its .drv file name, so afterwards the
      ;; realised output is a real store item and no reserved path was ever
      ;; sent to the daemon.
      (let ((refs (goonix-references-of-realised
                   store drv (derivation-output-names drv))))
        (and (list? refs)
             (not (any (lambda (ref)
                         (or (placeholder-path? ref)
                             (token-store-path? ref)))
                       refs))
             (let ((path (goonix-realised-output-path store drv "out")))
               (and path (not (placeholder-path? path)))))))
    ;; The graft itself: this is the call that used to kill the connection.
    ;; A real graft pair, so the rewriting path is exercised rather than a
    ;; no-op short circuit.
    (test-assert "computing the graft over the placeholder succeeds"
      (let ((orig (plain-drv (fresh-name "graft-orig") "ORIG"))
            (repl (plain-drv (fresh-name "graft-repl") "REPL")))
        (build-derivations store (list orig repl))
        (derivation? (graft-derivation store drv
                       (list (graft (origin orig) (replacement repl)))
                       #:guile guile-drv))))
    (test-assert "the connection is still usable afterwards"
      (valid-path? store (derivation->output-path guile-drv)))))

(test-group "an unrealised package is still grafted through its inputs"
  ;; The security property: a 'content package P whose input D has a
  ;; replacement D* must be GRAFTED, even though P's own output is an
  ;; unrealised placeholder at lowering time.  Grafts carry security fixes
  ;; (a glibc replacement), so dropping one silently is a vulnerability.
  ;;
  ;; Returning '() from the reserved-output path made cumulative-grafts read
  ;; "no dependencies" and return P ungrafted.  These assertions pin that the
  ;; graft really reaches P: a different derivation, and a built result that
  ;; refers to D*'s output and NOT to D's.
  (define (dep-package name payload)
    (package
      (name name)
      (version "1")
      (source #f)
      (build-system trivial-build-system)
      (arguments
       (list #:guile %bootstrap-guile
             #:builder #~(call-with-output-file #$output
                           (lambda (p) (display #$payload p)))))
      (synopsis "CA graft input test")
      (description "CA graft input test")
      (home-page #f)
      (license #f)))
  (define (user-package name dep)
    (package
      (name name)
      (version "1")
      (source #f)
      (build-system trivial-build-system)
      (inputs (list dep))
      (arguments
       (list #:guile %bootstrap-guile
             #:builder #~(call-with-output-file #$output
                           (lambda (p)
                             (format p "USES ~a" #$dep)))))
      (synopsis "CA graft consumer test")
      (description "CA graft consumer test")
      (home-page #f)
      (license #f)))
  ;; Guix grafts rewrite in place, so the origin and replacement names must
  ;; have the SAME LENGTH (guix/build/graft.scm refuses otherwise).  Real
  ;; grafts satisfy this by construction (glibc-2.39 -> glibc-2.39-grafted
  ;; style padding); the fixture pads D*'s name to D's length.
  (let* ((d-name  (fresh-name "ca-graft-dep"))
         (d*-name (string-append "ca-graft-rep"
                                 (make-string (- (string-length d-name)
                                                 (string-length "ca-graft-rep"))
                                              #\x)))
         (p-name  (fresh-name "ca-graft-user"))
         (dep     (dep-package d-name "DEP"))
         (dep*    (dep-package d*-name "DEP-STAR"))
         (pkg     (user-package p-name dep))
         (lower   (lambda (p)
                    (parameterize ((%package-addressing-policy 'content))
                      (package-derivation store p))))
         (p-drv   (lower pkg))
         (d-drv   (lower dep))
         (d*-drv  (lower dep*)))
    (test-assert "P's output is an unrealised placeholder"
      (and (placeholder-path? (derivation->output-path p-drv))
           (not (valid-path? store (derivation->output-path p-drv)))))
    ;; D and D* are realised, so their REALISED paths are what a reference
    ;; in P's built output will name.
    (build-derivations store (list d-drv d*-drv))
    (let* ((grafted (graft-derivation store p-drv
                      (list (graft (origin d-drv) (replacement d*-drv)))
                      #:guile guile-drv))
           (d-real  (realised-output-path store d-drv "out"))
           (d*-real (realised-output-path store d*-drv "out")))
      (test-assert "the graft changes P's derivation (it is not returned ungrafted)"
        (not (string=? (derivation-file-name grafted)
                       (derivation-file-name p-drv))))
      (build-derivations store (list grafted))
      (let* ((out   (realised-output-path store grafted "out"))
             (text  (read-all out))
             (refs  (references store out)))
        (test-assert "the built result refers to the REPLACEMENT's output"
          (or (member d*-real refs) (string-contains text d*-real)))
        (test-assert "the built result does not refer to the ORIGIN's output"
          (and (not (member d-real refs))
               (not (string-contains text d-real))))
        (test-assert "the payload was rewritten"
          (string-contains text d*-real))))
    (test-assert "the connection is still usable afterwards"
      (valid-path? store (derivation->output-path guile-drv)))))

(close-connection store)
(test-end)
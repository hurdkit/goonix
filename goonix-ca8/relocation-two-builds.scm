;;; goonix: the plan's section 4.4 relocation check, as TWO BUILDS.
;;;
;;; "A self path that is hashed, encrypted, encoded some other way, cut into
;;; pieces shorter than 8 characters, or used to compute something ... For
;;; these there is one sound test: build twice with two different tokens and
;;; compare."  A package that fails is marked opaque.
;;;
;;; WHY TWO BUILDS, NOT TWO REWRITES.  An earlier version rewrote one built
;;; artefact twice and compared.  Its calibration FAILED: a fixture writing a
;;; SHA256 of its own output path passed, because the builder computed that
;;; digest from the original path and no rewrite touches it, so both copies
;;; were byte-identical.  A hidden self reference is invisible to that method by
;;; construction.  The BUILDER must run twice, seeing a different self path.
;;;
;;; HOW THE TWO TOKENS ARISE.  A content-addressed builder is handed a
;;; placeholder derived from its DERIVATION BYTES (guix/ca.scm's placeholder),
;;; which the daemon finalises to the output's self token.  Two derivations
;;; differing only in an unused environment variable therefore hand the builder
;;; two DIFFERENT self paths while building the same thing.  Then:
;;;   - an honest builder's self references are rewritten to the token, so both
;;;     outputs have identical content and the SAME realised name;
;;;   - a builder that hides its own path produces different content, hence
;;;     DIFFERENT realised names.
;;; Comparing realised names IS the plan's test.
;;;
;;; Usage, inside the dev shell against a TEST store:
;;;   ./test-env ./pre-inst-env guile --no-auto-compile -L . \
;;;       -s goonix-ca8/relocation-two-builds.scm [--fixtures] [DRV...]
;;;
;;; --fixtures runs the calibration pair.  DRV arguments are .drv files judged
;;; the same way: each is rebuilt twice with the salt added.
;;;
;;; Exit: 0 when the calibration holds and every judged item relocates,
;;; 1 otherwise, 2 on usage/setup error.

(use-modules (guix)
             (guix tests)
             (guix ca)
             (gnu packages bootstrap)
             (guix derivations)
             (guix serialization)
             (ice-9 match)
             (ice-9 textual-ports)
             (rnrs bytevectors)
             (srfi srfi-1)
             (srfi srfi-11))

(define store (open-connection-for-tests))
(%graft? #f)

(define guile-drv (package-derivation store %bootstrap-guile))
(build-derivations store (list guile-drv))
(define bootstrap-guile
  (string-append (derivation->output-path guile-drv) "/bin/guile"))
(define bootstrap-guile-modules
  (string-append (derivation->output-path guile-drv) "/share/guile/2.0"))

(define (salted-drv name builder-text salt)
  "A content-addressed derivation running BUILDER-TEXT, differing from its
sibling ONLY in the unused goonixRelocationSalt variable.  Mirrors the shell-drv
idiom of tests/ca-build.scm (builder passed as __file:builder.scm, run from
$NIX_BUILD_TOP).

The item NAME must be IDENTICAL in both variants.  The plan varies the TOKEN,
not the name: two items named ...-a and ...-b can never have equal paths, so an
honest builder would fail for a naming reason.  Measured: the first calibration
reported honest-ok=#f with names reloc-honest-a != reloc-honest-b.  Same name,
different derivation bytes (the salt) -> different placeholder -> the builder
sees a different self path, which is what section 4.4 asks for."
  (derivation store name bootstrap-guile
              '("--no-auto-compile" "$NIX_BUILD_TOP/builder.scm")
              #:inputs (list guile-drv)
              #:outputs '("out")
              #:addressing 'content
              #:env-vars
              `(("GUILE_LOAD_PATH" . ,bootstrap-guile-modules)
                ("__files" . "builder.scm")
                ("__file:builder.scm" . ,builder-text)
                ("goonixRelocationSalt" . ,salt))))

(define (build-twice name builder-text)
  (define (variant salt)
    (let ((drv (salted-drv name builder-text salt)))
      (build-derivations store (list drv))
      ;; A content-addressed derivation's derivation->output-path is the
      ;; PLACEHOLDER, not the realised item.  Measured: comparing those gave
      ;; hashes like "eoeueueutueeut..." for both variants, which are not store
      ;; paths at all, so every fixture failed for the wrong reason.  Ask the
      ;; daemon which path it actually chose.
      (realised-output-path store drv "out")))
  (values (variant "a") (variant "b")))

(define (judge name a b)
  ;; Show what each build actually wrote, so a FAIL can be attributed to bytes
  ;; rather than guessed at.  Realised items may be a file or a directory.
  (define (peek p)
    (false-if-exception
     (cond ((file-is-directory? p)
            (format #f "<directory: ~a>" (length (scandir p))))
           (else
            (let ((s (call-with-input-file p get-string-all)))
              (substring s 0 (min 120 (string-length s))))))))
  (format #t "  a: ~a~%     content: ~s~%" (basename a) (peek a))
  (format #t "  b: ~a~%     content: ~s~%" (basename b) (peek b))
  (if (string=? a b)
      (begin (format #t "RELOCATE ~a PASS ~a~%" name (basename a)) #t)
      (begin (format #t "RELOCATE ~a FAIL ~a != ~a~%"
                     name (basename a) (basename b))
             #f)))

;; Honest: writes its own output path literally.  The rewriter reaches it, so
;; both builds have the same content and the same realised name.
;;
;; Both builders use ONLY what bootstrap guile 2.0 provides: no (gcrypt hash),
;; no (guix base32).  The first attempt imported them and the builder died with
;; "no code for module (gcrypt hash)", which made even the honest fixture fail
;; for a fixture reason rather than a relocation reason.
(define honest-builder
  "(define out (getenv \"out\"))
   (call-with-output-file out (lambda (p) (display out p)))")

;; Hiding: writes a digest of its own output path, computed with a plain
;; arithmetic hash so no module is needed.  No rewrite can find that digest, so
;; the two builds keep different content and different names.
(define hiding-builder
  "(define out (getenv \"out\"))
   (define (digest s)
     (let loop ((i 0) (h 5381))
       (if (= i (string-length s))
           h
           (loop (+ i 1)
                 (modulo (+ (* h 33) (char->integer (string-ref s i)))
                         1000000007)))))
   (call-with-output-file out
     (lambda (p) (display (digest out) p)))")

;; PROBE: what does the builder actually see in $out?
;;
;; The v6 calibration measured honest PASS but hiding ALSO PASS: both hiding
;; builds wrote the identical digest 711710712, so both builders saw the SAME
;; $out string.  The salt therefore did not vary the self path, which is the
;; whole mechanism this check rests on.  Reasoning about it is not enough; this
;; builder emits $out as space-separated character codes, which no rewriter can
;; match (it looks for the literal path and fragments of 8+ characters), so the
;; realised content reveals exactly what each build was handed.
(define probe-builder
  "(define out (getenv \"out\"))
   (call-with-output-file out
     (lambda (p)
       (let loop ((i 0))
         (when (< i (string-length out))
           (display (char->integer (string-ref out i)) p)
           (display \" \" p)
           (loop (+ i 1))))))")

(define (decode-codes s)
  (list->string
   (map integer->char
        (filter-map string->number (string-tokenize s)))))

(define (run-probe)
  (format #t "=== probe: what $out does each salted build see? ===~%")
  (let-values (((a b) (build-twice "reloc-probe" probe-builder)))
    (define (codes p)
      (false-if-exception
       (decode-codes (call-with-input-file p get-string-all))))
    (format #t "  a realised: ~a~%    $out seen: ~s~%" (basename a) (codes a))
    (format #t "  b realised: ~a~%    $out seen: ~s~%" (basename b) (codes b))
    (format #t "PROBE ~a~%"
            (if (equal? (codes a) (codes b))
                "SAME $out in both builds - the salt does NOT vary the self path"
                "DIFFERENT $out - the salt works"))
            #t))

(define (run-fixtures)
  (format #t "=== calibration: two builds per fixture ===~%")
  (let-values (((a b) (build-twice "reloc-honest" honest-builder)))
    (let ((honest-ok (judge "reloc-honest (must PASS)" a b)))
      (let-values (((c d) (build-twice "reloc-hiding" hiding-builder)))
        (let ((hiding-failed (not (judge "reloc-hiding (must FAIL)" c d))))
          ;; The calibration holds only if the honest one passed AND the hiding
          ;; one failed: a check that passed everything, or failed everything,
          ;; is caught here.
          (if (and honest-ok hiding-failed)
              (begin (format #t "CALIBRATION PASS~%") #t)
              (begin (format #t "CALIBRATION FAIL honest-ok=~a hiding-failed=~a~%"
                             honest-ok hiding-failed)
                     #f)))))))

;; Judging a real derivation: rebuild it twice with the salt added, keeping its
;; builder, arguments, inputs, sources and every other environment entry.
;;
;; Three things must match the fixture path, each learned by measurement:
;;   - the SAME item name in both variants (the token varies, not the name);
;;   - realised-output-path, not derivation->output-path, which is the CA
;;     placeholder;
;;   - the inputs are passed as the ORIGINAL derivation-input records, not
;;     (map derivation-input-derivation ...): that map drops each input's
;;     sub-output selection and would silently ask for "out" of glibc's lib or
;;     gcc's lib, changing what is being built.
;; An "out" entry copied from the old environment is harmless: derivation's
;; env-vars-with-empty-outputs blanks every variable named after an output, and
;; the daemon fills in the placeholder.
(define (judge-drv path)
  (let* ((drv (call-with-input-file path read-derivation))
         (name (derivation-name drv))
         (env (derivation-builder-environment-vars drv)))
    (define (variant salt)
      (let ((d (derivation store name
                           (derivation-builder drv)
                           (derivation-builder-arguments drv)
                           #:inputs (derivation-inputs drv)
                           #:sources (derivation-sources drv)
                           #:outputs (derivation-output-names drv)
                           #:system (derivation-system drv)
                           #:addressing 'content
                           #:env-vars (cons (cons "goonixRelocationSalt" salt)
                                            (filter (lambda (e)
                                                      (not (string=?
                                                            (car e)
                                                            "goonixRelocationSalt")))
                                                    env)))))
        (build-derivations store (list d))
        (realised-output-path store d "out")))
    (judge name (variant "a") (variant "b"))))

(define (main args)
  (let* ((argv (cdr args))
         (fixtures? (member "--fixtures" argv))
         (probe? (member "--probe" argv))
         (rest (filter (lambda (a)
                         (not (member a '("--fixtures" "--probe"))))
                       argv)))
    (cond
     (probe?
      (run-probe)
      (close-connection store)
      0)
     ((and (not fixtures?) (null? rest))
      (format (current-error-port)
              "usage: relocation-two-builds.scm [--fixtures|--probe] [DRV...]~%")
      2)
     (else
      (let ((cal (if fixtures? (run-fixtures) #t)))
        (let loop ((items rest) (failed 0))
          (if (null? items)
              (begin
                (format #t "RELOCATION ~a items judged, ~a failed~%"
                        (length rest) failed)
                (close-connection store)
                (if (and cal (zero? failed)) 0 1))
              (let ((ok (catch #t
                          (lambda () (judge-drv (car items)))
                          (lambda (key . args)
                            (format #t "RELOCATE ~a FAIL ~a ~a~%"
                                    (basename (car items)) key args)
                            #f))))
                (loop (cdr items) (if ok failed (+ failed 1)))))))))))

(exit (main (command-line)))
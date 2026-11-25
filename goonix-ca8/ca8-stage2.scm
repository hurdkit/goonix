;;; goonix: CA-8 core stage 2 — the toolchain tail, BUILT content-addressed,
;;; then the plan's section 4.4 relocation check on every item it built.
;;;
;;; DECISIONS.md: CA-8's "the world builds" is THE CORE TOOLCHAIN — "from the
;;; seeds through glibc, gcc and guile, content-addressed, with the relocation
;;; check of plan section 4.4 on those items".  Stage 1 covers the seeds and the
;;; mesboot ladder up to coreutils-mesboot; this stage carries the chain the rest
;;; of the way and then relocates what it built.
;;;
;;; Same two-pass rule as stage 1, and for the same reason (reviewer point 1:
;;; the substitution rule is "is it fixed-output", never the item's name):
;;;   PASS 1  every FIXED-OUTPUT derivation of the whole chain, substitutes ON.
;;;   PASS 2  the chain itself, substitutes OFF, so nothing that is not
;;;           fixed-output can arrive from a substitute server.
;;;
;;; Section 4.4 is the one sound test for a self path that scanning cannot see
;;; (hashed, encoded, fragmented, or used to compute a file name): build twice
;;; with two different tokens and compare.  relocation-check.scm performs that
;;; comparison on an ALREADY REALISED item by copying it out and rewriting its
;;; self references to two different tokens, so it does not rebuild the chain
;;; and only READS the store.  It runs here, on the items this stage built, in
;;; the same job — an item that fails is marked opaque, which is the plan's
;;; verdict, not a silent pass.
;;;
;;; Runs under goonix-ca8/ca8-core-run.sh, exactly as stage 1 does:
;;;   bash goonix-ca8/ca8-core-run.sh stage2 goonix-ca8/ca8-stage2.scm
(use-modules (guix)
             (guix store)
             (guix monads)
             (guix gexp)
             (guix derivations)
             (guix packages)
             (guix ca policy)
             (gnu packages bootstrap)
             (ice-9 match)
             (ice-9 textual-ports)
             (ice-9 exceptions)
             (ice-9 ftw)
             (srfi srfi-1)
             (srfi srfi-13))

(define commencement (resolve-module '(gnu packages commencement)))
(define (stage name)
  "The commencement stage NAME, or #f if it does not resolve to a package.
Most stages are plain private variables, so module-ref gives a package directly.
The ones defined with define/system-dependent - glibc-final among them - are
identifier-syntax over a memoised thunk NAME/memoized, so the module variable
holds a SYNTAX TRANSFORMER, not a package.  Passing that transformer on to
package->bag fails with
  struct-vtable: Wrong type argument in position 1 (expecting struct):
  #<syntax-transformer glibc-final>
which is what ended the 2026-11-24 stage2 run one second after it started.
Take the transformer only when it IS a package, else call NAME/memoized with
%current-system.  Same fallback as .scratch/ca8-dry-run.scm:26-36 and
.scratch/ca8-glibc-diag.scm:14-19, where it was verified to lower glibc-final
cleanly (three outputs out, debug, static)."
  (or (false-if-exception
       (let ((value (module-ref commencement name)))
         (and (package? value) value)))
      (false-if-exception
       (let ((thunk (module-ref commencement
                                (symbol-append name '/memoized))))
         (thunk (%current-system))))))
(define (addressing drv)
  (assoc-ref (derivation-builder-environment-vars drv) "goonixAddressing"))
(define (fixed-output? drv)
  ;; The derivation's own output hash, never the item's name (reviewer point 1).
  (any (lambda (output) (derivation-output-hash (cdr output)))
       (derivation-outputs drv)))

(define (transitive-inputs drv)
  "Every derivation reachable from DRV through its inputs, DRV included, once."
  (let loop ((pending (list drv)) (seen '()) (result '()))
    (if (null? pending)
        result
        (let ((current (car pending)) (rest (cdr pending)))
          (if (member (derivation-file-name current) seen)
              (loop rest seen result)
              (loop (append rest (map derivation-input-derivation
                                      (derivation-inputs current)))
                    (cons (derivation-file-name current) seen)
                    (cons current result)))))))

(define store (open-connection))

;;; The tail of the core toolchain.  glibc-final and gcc-final are the items the
;;; reviewer's exact lowering command names; guile-final is the last of the three
;;; the decision requires.  Everything before them in this list is what they
;;; need beyond stage 1's ladder.  A name that does not resolve in this tree is
;;; reported as MISSING and fails the stage rather than being skipped quietly:
;;; a chain with a hole in it is not a pass.
;;;
;;; GOONIX_CA8_STAGE2_CHAIN selects a SMALLER chain of the same shape, so this
;;; script can be verified end to end (both passes, the relocation step, the
;;; verdict) in minutes on a fixture instead of hours on the real toolchain.
;;; It is a comma-separated list of VARIABLE names resolved in the same module,
;;; e.g. "hello-minimal" or "gash-boot,make-mesboot0".  The DEFAULT is unchanged:
;;; the three toolchain items.  A selected chain is printed, and the verdict
;;; names it, so a small-chain run can never be mistaken for the toolchain gate.
(define chain-names
  (let ((env (getenv "GOONIX_CA8_STAGE2_CHAIN")))
    (if (or (not env) (string-null? env))
        '(glibc-final gcc-final guile-final)
        (map (lambda (s) (string->symbol (string-trim-both s)))
             (string-split env #\,)))))
(define chain
  (map (lambda (name)
         (list (string-append "stage: " (symbol->string name)) (stage name)))
       chain-names))
(format #t "STAGE2 CHAIN ~a~%" chain-names)

(define missing
  (filter-map (match-lambda ((label package) (and (not package) label))) chain))
(unless (null? missing)
  (format #t "STAGE2 MISSING ~a~%" missing)
  (format #t "STAGE2 EXIT=1 (unresolved package names)~%")
  (exit 1))

(set-build-options store #:use-substitutes? #t
                   #:substitute-urls (list "https://bordeaux.guix.gnu.org"))

(format #t "CA-8 core STAGE 2 — glibc, gcc, guile, 'content + section 4.4~%")

(define (elapsed thunk)
  (let ((start (get-internal-real-time)))
    (let ((value (thunk)))
      (cons value (/ (- (get-internal-real-time) start)
                     internal-time-units-per-second 1.0)))))

;;; PASS 1 — fixed-output sources of the tail, substitutes ON.
(format #t "~%--- PASS 1: fixed-output sources, substitutes ON ---~%")
(define lowerings
  (filter-map
   (match-lambda
     ((label package)
      (and package
           (cons label
                 (parameterize ((%package-addressing-policy 'content))
                   (package-derivation store package))))))
   chain))

(define fo-seen '())
(define fo-fetched 0)
(define fo-present 0)
(define fo-failed 0)
(for-each
 (match-lambda
   ((label . drv)
    (for-each
     (lambda (input-drv)
       (let ((file (derivation-file-name input-drv)))
         (when (and (fixed-output? input-drv) (not (member file fo-seen)))
           (set! fo-seen (cons file fo-seen))
           (let ((out (derivation->output-path input-drv)))
             (if (valid-path? store out)
                 (begin (set! fo-present (+ fo-present 1))
                        (format #t "FO\tALREADY-PRESENT\t~a~%" out))
                 (catch #t
                   (lambda ()
                     (build-derivations store (list input-drv))
                     (set! fo-fetched (+ fo-fetched 1))
                     (format #t "FO\tSUBSTITUTED\t~a~%" out))
                   (lambda (key . args)
                     (set! fo-failed (+ fo-failed 1))
                     (format #t "FO\tFAILED\t~a\t~a ~a~%" out key args))))))))
     (transitive-inputs drv))))
 lowerings)
(format #t "PASS1 TOTALS substituted=~a already-present=~a failed=~a~%"
        fo-fetched fo-present fo-failed)
(when (> fo-failed 0)
  (format #t "STAGE2 EXIT=1 (fixed-output pass failed)~%")
  (exit 1))

;;; PASS 2 — the tail itself, substitutes OFF.  Only BUILT-HERE counts.
(format #t "~%--- PASS 2: the toolchain tail, substitutes OFF ---~%")
(set-build-options store #:use-substitutes? #f)

(define built '())
(define substituted 0)
(define failed 0)
(for-each
 (match-lambda
   ((label . drv)
    (let ((kind (addressing drv)))
      ;; goonix: a CONTENT-ADDRESSED derivation's derivation->output-path is the
      ;; PLACEHOLDER (a reserved 'eout' token), not the realised item.  Ask the
      ;; daemon which path it chose, before AND after the build, exactly as
      ;; relocation-two-builds.scm does.  Using the token here made the
      ;; relocation step fail with "invalid replacement" on a path that is not a
      ;; store item at all (measured on gash-boot:
      ;; /gnu/store/etuteotoouooutuuoototeuouuuueteo-gash-boot-0.3.1).
      (define (realised)
        (false-if-exception (realised-output-path store drv "out")))
      (let ((before-path (realised)))
        (catch #t
          (lambda ()
            (let* ((result (elapsed (lambda ()
                                      (build-derivations store (list drv)))))
                   (secs (cdr result))
                   (out (or (realised) (derivation->output-path drv))))
              (if before-path
                  (begin (set! substituted (+ substituted 1))
                         (format #t "~a\tALREADY-PRESENT\t~a\t~a\t~,1fs~%"
                                 label kind out secs))
                  (begin (set! built (cons (cons label out) built))
                         (format #t "~a\tBUILT-HERE\t~a\t~a\t~,1fs~%"
                                 label kind out secs)))))
          (lambda (key . args)
            (set! failed (+ failed 1))
            (format #t "~a\tFAILED\t~a~%" label
                    (with-output-to-string
                      (lambda () (display key) (display " ") (write args))))
            ;; A failed stage stops the chain (the reviewer's rule).
            (raise-exception
             (make-exception (make-exception-with-message
                              (string-append label " failed"))
                             (make-exception-with-irritants args)))))))))
 lowerings)
(format #t "STAGE2 TOTALS built=~a already-present=~a failed=~a~%"
        (length built) substituted failed)

;;; Section 4.4 on every item this stage BUILT.  Already-present items were not
;;; built by this daemon, so relocating them would be a verdict on somebody
;;; else's build; they are named and skipped explicitly, not silently.
;;;
;;; The check runs IN THIS PROCESS, not as a sub-command.  (car (command-line))
;;; inside `guile -s` is the SCRIPT PATH, not the interpreter (measured), so
;;; spawning it would fail; and a fresh guile would have to re-resolve the whole
;;; module graph per item.  relocation-check.scm ends with (exit (main ...)), so
;;; it cannot simply be loaded either.  Read its body, drop that final call, and
;;; evaluate it here: check-item then runs against this daemon's own store
;;; connection and module set.
(format #t "~%--- SECTION 4.4: relocation of the items built here ---~%")
(define relocate-script
  (string-append (dirname (current-filename)) "/relocation-check.scm"))
(define reloc-pass 0)
(define reloc-fail 0)
(define reloc-skipped 0)

(define check-item
  (let* ((forms (with-input-from-file relocate-script
                  (lambda ()
                    (let loop ((acc '()))
                      (let ((form (read)))
                        (if (eof-object? form) (reverse acc)
                            (loop (cons form acc))))))))
         ;; Drop the trailing (exit (main (command-line))) entry point.
         (body (filter (lambda (f)
                         (not (and (pair? f) (eq? (car f) 'exit))))
                       forms)))
    (for-each (lambda (f) (primitive-eval f)) body)
    (module-ref (current-module) 'check-item)))

(for-each
 (match-lambda
   ((label . out)
    (format #t "RELOCATE-BEGIN ~a ~a~%" label out)
    (match (false-if-exception (check-item out))
      (('pass why)
       (set! reloc-pass (+ reloc-pass 1))
       (format #t "RELOCATE ~a PASS ~a~%" label why))
      (('fail why)
       (set! reloc-fail (+ reloc-fail 1))
       (format #t "RELOCATE ~a FAIL ~a~%" label why)
       (format #t "OPAQUE ~a ~a~%" label out))
      (other
       ;; An exception is NOT a pass: the check did not reach a verdict.
       (set! reloc-fail (+ reloc-fail 1))
       (format #t "RELOCATE ~a ERROR ~s~%" label other)))))
 (reverse built))
(format #t "RELOCATION TOTALS pass=~a opaque=~a~%" reloc-pass reloc-fail)

(close-connection store)
(if (and (zero? failed) (zero? reloc-fail) (> (length built) 0))
    (format #t "STAGE2 VERDICT PASS chain=~a~%" chain-names)
    (begin (format #t "STAGE2 VERDICT FAIL chain=~a~%" chain-names) (exit 1)))
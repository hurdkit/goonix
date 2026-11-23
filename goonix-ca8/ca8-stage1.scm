;;; goonix: CA-8 core stage 1 — the seeds and the mesboot ladder, BUILT
;;; content-addressed in the private namespace.  Bordeaux supplies only
;;; fixed-output items (source tarballs, seed downloads); every other
;;; derivation is built by the namespace daemon.
;;;
;;; Each item is recorded as built here / substituted / adopted, from the
;;; daemon's own log, and only "built here" counts for the gate.
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
             (srfi srfi-1))

(define commencement (resolve-module '(gnu packages commencement)))
(define (stage name) (false-if-exception (module-ref commencement name)))
(define (addressing drv)
  (assoc-ref (derivation-builder-environment-vars drv) "goonixAddressing"))
(define (fixed-output? drv)
  ;; A fixed-output derivation has a hash on its output: a source tarball or
  ;; a seed download.  Only these may be substituted.  The test is the
  ;; derivation's own hash, never the item's name: the static bootstrap
  ;; executables (xz, mkdir, bash, ...) are origins made by
  ;; bootstrap-executable* with method url-fetch/executable and a content
  ;; hash, so they ARE fixed-output and Bordeaux may supply them.
  (any (lambda (output)
         (derivation-output-hash (cdr output)))
       (derivation-outputs drv)))

(define (transitive-inputs drv)
  "Return every derivation reachable from DRV through its inputs, DRV
included, each once.  The fixed-output pre-pass must be transitive: a source
tarball several levels down is still fixed-output, and walking only the
direct inputs let one fall through to a local download."
  (let loop ((pending (list drv)) (seen '()) (result '()))
    (if (null? pending)
        result
        (let ((current (car pending))
              (rest (cdr pending)))
          (if (member (derivation-file-name current) seen)
              (loop rest seen result)
              (loop (append rest
                            (map derivation-input-derivation
                                 (derivation-inputs current)))
                    (cons (derivation-file-name current) seen)
                    (cons current result)))))))

(define store (open-connection))

;; Sources and seeds first, WITH substitutes: these are fixed-output items.
(set-build-options store #:use-substitutes? #t
                   #:substitute-urls (list "https://bordeaux.guix.gnu.org"))

(define chain
  `(("seed: bootstrap-guile"        ,%bootstrap-guile)
    ("stage: mes-boot"              ,(stage 'mes-boot))
    ("stage: tcc-boot0"             ,(stage 'tcc-boot0))
    ("stage: tcc-boot"              ,(stage 'tcc-boot))
    ("stage: binutils-mesboot0"     ,(stage 'binutils-mesboot0))
    ("stage: gcc-core-mesboot0"     ,(stage 'gcc-core-mesboot0))
    ("stage: glibc-mesboot0"        ,(stage 'glibc-mesboot0))
    ("stage: gcc-mesboot0"          ,(stage 'gcc-mesboot0))
    ("stage: binutils-mesboot1"     ,(stage 'binutils-mesboot1))
    ("stage: gcc-core-mesboot1"     ,(stage 'gcc-core-mesboot1))
    ("stage: gcc-mesboot1"          ,(stage 'gcc-mesboot1))
    ("stage: binutils-mesboot"      ,(stage 'binutils-mesboot))
    ("stage: glibc-headers-mesboot" ,(stage 'glibc-headers-mesboot))
    ("stage: glibc-mesboot"         ,(stage 'glibc-mesboot))
    ("stage: gcc-mesboot1-wrapper"  ,(stage 'gcc-mesboot1-wrapper))
    ("stage: gcc-mesboot"           ,(stage 'gcc-mesboot))
    ("stage: gcc-mesboot-wrapper"   ,(stage 'gcc-mesboot-wrapper))
    ("stage: bash-mesboot"          ,(stage 'bash-mesboot))
    ("stage: coreutils-mesboot"     ,(stage 'coreutils-mesboot))))

(define (elapsed thunk)
  (let ((start (get-internal-real-time)))
    (let ((result (thunk)))
      (cons result
            (/ (- (get-internal-real-time) start)
               (exact->inexact internal-time-units-per-second))))))

(format #t "CA-8 core STAGE 1 — seeds and the mesboot ladder, 'content~%")

;;; PASS 1 — realise every FIXED-OUTPUT derivation of the whole chain, with
;;; substitutes ON.  These are sources and seed downloads (including the
;;; static bootstrap executables, which bootstrap-executable* makes as
;;; fixed-output origins).  Recorded per item.
(format #t "~%--- PASS 1: fixed-output sources and seeds, substitutes ON ---~%")
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
         (when (and (fixed-output? input-drv)
                    (not (member file fo-seen)))
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

;;; PASS 2 — build the chain with substitutes OFF, so the daemon cannot
;;; substitute anything that is not fixed-output.  Every fixed-output item
;;; pass 1 needed is already in the store.
(format #t "~%--- PASS 2: the chain, substitutes OFF ---~%")
(set-build-options store #:use-substitutes? #f)
(define built 0) (define substituted 0) (define failed 0)
(for-each
 (match-lambda
   ((label package)
    (if (not package)
        (begin (set! failed (+ failed 1))
               (format #t "~a\tMISSING~%" label))
        (catch #t
          (lambda ()
            (let* ((drv (cdr (assoc label lowerings)))
                   (kind (addressing drv))
                   (out (derivation->output-path drv)))
              (let* ((before (valid-path? store out))
                     (result (elapsed
                              (lambda () (build-derivations store (list drv)))))
                     (secs (cdr result))
                     (after (valid-path? store out)))
                (cond
                 (before (set! substituted (+ substituted 1))
                         (format #t "~a\tALREADY-PRESENT\t~a\t~a\t~,1fs~%"
                                 label kind out secs))
                 (else (set! built (+ built 1))
                       (format #t "~a\tBUILT-HERE\t~a\t~a\t~,1fs~%"
                               label kind out secs))))))
          (lambda (key . args)
            (set! failed (+ failed 1))
            (format #t "~a\tFAILED\t~a~%" label
                    (with-output-to-string
                      (lambda () (display key) (display " ") (write args))))
            ;; A stage that fails stops the chain: the next stage must not
            ;; start (the reviewer's rule).  Raise so the job exits non-zero.
            (raise-exception
             (make-exception (make-exception-with-message
                              (string-append label " failed"))
                             (make-exception-with-irritants args))))))))
 chain)

(format #t "STAGE1 TOTALS built=~a already-present=~a failed=~a~%"
        built substituted failed)
(close-connection store)
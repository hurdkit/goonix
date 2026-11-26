;;; goonix: CA-8 — the opaque table applied at lowering.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (test-ca-opaque)
  #:use-module (guix)
  #:use-module (guix tests)
  #:use-module (guix utils)
  #:use-module (guix ca)
  #:use-module (guix ca opaque)
  #:use-module (guix ca policy)
  #:use-module (guix ca scan)
  #:use-module (guix ca adopt)
  #:use-module (guix packages)
  #:use-module (guix build-system)
  #:use-module (guix derivations)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bootstrap)
  #:use-module (gnu packages virtualization)
  #:use-module (gnu packages file)
  #:use-module (ice-9 binary-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-64))

;;; Commentary:
;;;
;;; "Every opaque package is marked" (CA-8): gnu/packages is never edited, so
;;; the marking comes from the goonix table (guix ca opaque), applied at
;;; lowering exactly as the opaque property.  The table starts from the
;;; scanner's result on this store: glibc, qemu-minimal and file.
;;;
;;; - under the full policy, glibc, qemu-minimal and file lower
;;;   resolved-addressed by the table ALONE (no opaque property);
;;; - a package the table does not name, and the scanner does not flag, is
;;;   content-addressed.
;;;
;;; Code:

(test-begin "ca-opaque")

(define store (open-connection-for-tests))
(%graft? #f)

(define stage0-posix
  (module-ref (resolve-module '(gnu packages commencement)) 'stage0-posix))
(define mes-boot
  (module-ref (resolve-module '(gnu packages commencement)) 'mes-boot))

(define (addressing drv)
  (assoc-ref (derivation-builder-environment-vars drv) "goonixAddressing"))

(define (lower package)
  (parameterize ((%package-addressing-policy 'full))
    (package-derivation store package)))

(test-group "the table marks glibc, qemu-minimal and file resolved, by name alone"
  ;; None of these carries the opaque property in gnu/packages; the table
  ;; alone must make them resolved-addressed.
  (test-assert "glibc has no opaque property in gnu/packages"
    (not (eq? 'opaque (assq-ref (package-properties glibc) 'self-references))))
  (test-equal "glibc lowers resolved by the table alone"
    "resolved" (addressing (lower glibc)))
  (test-equal "qemu-minimal lowers resolved by the table alone"
    "resolved" (addressing (lower qemu-minimal)))
  (test-equal "file lowers resolved by the table alone"
    "resolved" (addressing (lower file))))

(test-group "a package the table does not name is content-addressed"
  (test-assert "hello is not opaque" (not (opaque-package? hello)))
  (test-equal "hello lowers content under full"
    "content" (addressing (lower hello)))
  (test-assert "coreutils is not opaque" (not (opaque-package? coreutils)))
  (test-equal "coreutils lowers content under full"
    "content" (addressing (lower coreutils))))

(test-group "the opaque property still marks a package the table does not name"
  (let ((marked (package
                  (inherit hello)
                  (properties '((self-references . opaque))))))
    (test-assert "a property-marked package is opaque" (opaque-package? marked))
    (test-equal "a property-marked package lowers resolved"
      "resolved" (addressing (lower marked)))))

(test-group "the opaque table applies under 'content without promotion under 'adopted"
  ;; Under 'adopted a tabled package keeps its input address and is not
  ;; adopted.  Its upstream dependents stay input-addressed before their own
  ;; adoption.  Under 'content the table still selects resolved addressing.
  (define (addressing-under policy package)
    (parameterize ((%package-addressing-policy policy))
      (package-addressing package)))

  (for-each
   (lambda (package)
     (test-assert
         (format #f "~a is in the opaque table (sanity)" (package-name package))
       (opaque-package? package))
     (test-equal
         (format #f "~a stays input under 'adopted (option 2)"
                 (package-name package))
       'input
       (addressing-under 'adopted package))
     (test-equal
         (format #f "~a still lowers resolved under 'content (no drift)"
                 (package-name package))
       'resolved
       (addressing-under 'content package)))
   (list glibc qemu-minimal file))

  (test-equal "glibc-utf8-locales, which depends on glibc, is not itself opaque"
    #f
    (opaque-package? glibc-utf8-locales))

  (test-equal "a package the table does not name stays input under 'adopted"
    ;; The fix must not turn the whole adopted graph resolved: only tabled
    ;; (or property-marked) packages change.  hello is upstream's and unmarked,
    ;; so it keeps upstream's input addressing and byte-identity.
    'input
    (addressing-under 'adopted hello))

  (test-equal "an upstream unmarked package still lowers content under 'content"
    'content
    (addressing-under 'content hello)))

(test-group "module compilation is cached per addressing policy"
  (let* ((guile (parameterize ((%package-addressing-policy 'input)
                               (%graft? #f))
                  (package-derivation store %bootstrap-guile)))
         (full (parameterize ((%package-addressing-policy 'full)
                              (%graft? #f))
                 (run-with-store store
                   (gexp->derivation "ca-policy-module-cache"
                                     #~(mkdir #$output)
                                     #:guile-for-build guile
                                     #:modules '((guix build utils))))))
         (input (parameterize ((%package-addressing-policy 'input)
                               (%graft? #f))
                  (run-with-store store
                    (gexp->derivation "ca-policy-module-cache"
                                      #~(mkdir #$output)
                                      #:guile-for-build guile
                                      #:modules '((guix build utils)))))))
    (test-equal "the full module builder is content-addressed"
      "content" (addressing full))
    (test-equal "the input module builder is input-addressed"
      #f (addressing input))
    (test-equal "the two policies have distinct module derivations"
      #f (equal? (derivation-file-name full) (derivation-file-name input)))))

(test-group "opaque adopted lowering is byte-identical to input lowering"
  ;; No output is built here.  Grafts are disabled for both lowerings, so
  ;; neither one needs the references of a realised grafted output.
  (for-each
   (lambda (package)
     (let ((input (parameterize ((%package-addressing-policy 'input)
                                 (%graft? #f))
                    (package-derivation store package)))
           (adopted (parameterize ((%package-addressing-policy 'adopted)
                                   (%graft? #f))
                      (package-derivation store package))))
       (test-equal
           (format #f "~a keeps its upstream .drv under 'adopted"
                   (package-name package))
         (derivation-file-name input)
         (derivation-file-name adopted))))
   (list glibc file qemu-minimal))
  (let* ((marked (package (inherit hello)
                   (properties '((self-references . opaque)))))
         (input (parameterize ((%package-addressing-policy 'input)
                               (%graft? #f))
                  ;; An opaque property selects resolved addressing under
                  ;; 'input too.  Compare against the otherwise identical
                  ;; upstream package, not against that resolved derivation.
                  (package-derivation store hello)))
         (adopted (parameterize ((%package-addressing-policy 'adopted)
                                 (%graft? #f))
                    (package-derivation store marked))))
    (test-equal "a property-marked package keeps its upstream .drv under 'adopted"
      (derivation-file-name input)
      (derivation-file-name adopted))))

(test-group "option 2 keeps opaque items input-addressed and unadopted"
  (define (under-adopted package)
    (parameterize ((%package-addressing-policy 'adopted))
      (list (package-addressing package) (adopt-package? package))))
  (test-equal "hello keeps its input then adopt route"
    '(input #t) (under-adopted hello))
  (for-each
   (lambda (package)
     (test-equal
         (format #f "~a stays input-addressed and unadopted under 'adopted"
                 (package-name package))
       '(input #f)
       (under-adopted package)))
   (list glibc file qemu-minimal))
  (let ((marked (package (inherit hello)
                  (properties '((self-references . opaque))))))
    (test-equal "a property-marked non-glibc package is also unadopted"
      '(input #f) (under-adopted marked))))

(test-group "bootstrap packages retain upstream input addressing under adopted"
  ;; No builds: adoption returns its original input derivation here, so this
  ;; isolates the policy's handling of dependents from the scanner and network.
  ;; Both source modules are covered.  Package locations can point at
  ;; bootstrap.scm even for bindings implemented in commencement.scm.
  (define (under-adopted package)
    (parameterize ((%package-addressing-policy 'adopted))
      (list (package-addressing package) (adopt-package? package))))
  (for-each
   (lambda (package)
     (test-equal
         (format #f "~a (~a) is input-addressed and unadopted under 'adopted"
                 (package-name package)
                 (location-file (package-location package)))
       '(input #f) (under-adopted package)))
   (list %bootstrap-guile stage0-posix mes-boot))
  (test-equal "hello outside the bootstrap boundary remains adoptable"
    '(input #t) (under-adopted hello))
  (let* ((adopt-module (resolve-module '(guix ca adopt)))
         (real-adopt (module-ref adopt-module 'adopt-derivation))
         (identity-adopt (lambda (store drv . args) drv)))
    (dynamic-wind
      (lambda ()
        (module-set! adopt-module 'adopt-derivation identity-adopt))
      (lambda ()
        (for-each
         (lambda (package)
           (let ((input (parameterize ((%package-addressing-policy 'input)
                                       (%graft? #f))
                          (package-derivation store package #:graft? #f)))
                 (adopted (parameterize ((%package-addressing-policy 'adopted)
                                        (%graft? #f))
                            (package-derivation store package #:graft? #f))))
             (test-equal
                 (format #f "~a keeps its upstream .drv under 'adopted"
                         (package-name package))
               (derivation-file-name input) (derivation-file-name adopted))))
         (list stage0-posix mes-boot)))
      (lambda ()
        (module-set! adopt-module 'adopt-derivation real-adopt))))
  ;; Direct form of the dependent route, using the real bootstrap inputs.
  ;; This is the no-build assertion that is RED before the boundary rule.
  (parameterize ((%package-addressing-policy 'adopted))
    (let ((adopted (parameterize ((%package-addressing-policy 'adopted))
                     (package-derivation store stage0-posix #:graft? #f))))
      (test-equal "a bootstrap dependent remains input-addressed"
        'input
        (gexp-addressing 'input (derivation-input adopted) '() #f #f #f)))))

(test-group "the adopted hello package closure respects opaque inputs"
  ;; This is a package-graph invariant, not a count of changed objects and
  ;; not a build.  Production package-addressing decides every edge.
  (define (under-adopted package)
    (parameterize ((%package-addressing-policy 'adopted))
      (package-addressing package)))
  (define records
    (map (lambda (package)
           (let ((bag (package->bag package)))
             (cons package
                   (parameterize ((%current-system (bag-system bag))
                                  (%current-target-system (bag-target bag)))
                     (filter-map
                      (match-lambda ((label (? package? p) . _) p) (_ #f))
                      (append (bag-build-inputs bag) (bag-host-inputs bag)
                              (bag-target-inputs bag)))))))
         (package-closure (list hello))))
  (define (inputs package) (or (assq-ref records package) '()))
  (test-assert "no input-addressed package has a non-input package input"
    (every (lambda (record)
             (let ((package (car record)))
               (or (not (eq? 'input (under-adopted package)))
                   (every (lambda (input)
                            (eq? 'input (under-adopted input)))
                          (inputs package)))))
           records))
  (test-assert "every opaque package in hello's closure stays input and unadopted"
    (every (lambda (record)
             (let ((package (car record)))
               (or (not (opaque-package? package))
                   (parameterize ((%package-addressing-policy 'adopted))
                     (and (eq? 'input (package-addressing package))
                          (not (adopt-package? package)))))))
           records))
  (test-assert "every bootstrap package in hello's closure stays input and unadopted"
    (every (lambda (record)
             (let ((package (car record)))
               (or (not (member (location-file (package-location package))
                                '("gnu/packages/commencement.scm"
                                  "gnu/packages/bootstrap.scm")))
                   (parameterize ((%package-addressing-policy 'adopted))
                     (and (eq? 'input (package-addressing package))
                          (not (adopt-package? package)))))))
           records)))

(test-group "a scan flags exactly the covered fixtures, not the rewritable ones"
  ;; "Every opaque package is marked" becomes a check: the scanner flags
  ;; precisely the fixtures the table or the property covers (a self-reference
  ;; the rewriter cannot reverse), and does not flag a plain rewritable one.
  (define hash "0123456789abcdfghijklmnpqrsvwxyz")
  (define (fixture name thunk)
    (call-with-temporary-directory
     (lambda (root)
       (let ((item (string-append root "/" hash "-" name)))
         (mkdir item)
         (thunk item)
         (item-flagged? store item)))))
  ;; Covered: a split piece of the hash (a fragment) — not provably rewritable.
  (test-assert "a fragment fixture is flagged (covered)"
    (fixture "fragment"
             (lambda (item)
               (call-with-output-file (string-append item "/f")
                 (lambda (p) (display (substring hash 3 15) p))))))
  ;; Covered: a UTF-16LE encoding of the hash.
  (test-assert "a UTF-16 fixture is flagged (covered)"
    (fixture "utf16"
             (lambda (item)
               (call-with-output-file (string-append item "/f")
                 (lambda (p)
                   (put-bytevector p (string->utf16 hash (endianness little))))))))
  ;; Covered: a self-referencing symlink.
  (test-assert "a self-link fixture is flagged (covered)"
    (fixture "link"
             (lambda (item) (symlink hash (string-append item "/l")))))
  ;; Not covered: a whole plain self-reference is rewritable.
  (test-assert "a whole plain self-reference is not flagged (rewritable)"
    (not (fixture "whole"
                  (lambda (item)
                    (call-with-output-file (string-append item "/f")
                      (lambda (p) (display hash p)))))))
  ;; Not covered: no self-reference at all.
  (test-assert "a plain fixture is not flagged"
    (not (fixture "plain"
                  (lambda (item)
                    (call-with-output-file (string-append item "/f")
                      (lambda (p) (display "ordinary content" p))))))))

(close-connection store)
(test-end "ca-opaque")
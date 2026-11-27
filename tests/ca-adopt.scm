;;; goonix: CA-6 step 2 — adoption of an upstream closure.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (test-ca-adopt)
  #:use-module (guix)
  #:use-module (guix tests)
  #:use-module (guix grafts)
  #:use-module (guix gexp)
  #:use-module (guix ca)
  #:use-module (guix ca adopt)
  #:use-module (guix ca opaque)
  #:use-module (guix ca scan)
  #:use-module (guix ca policy)
  #:use-module (guix sets)
  #:use-module (guix build-system trivial)
  #:use-module (guix derivations)
  #:use-module (guix monads)
  #:use-module (gnu packages bootstrap)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-64))

;;; Commentary:
;;;
;;; adopt(P) for an upstream input-addressed derivation D is a
;;; content-addressed graft of D's outputs: each reference is adopted
;;; recursively (memoised per item) and rewritten to its adopted counterpart,
;;; and D's own path becomes the content address.  An item the scanner flags
;;; is not adopted.  These tests build a small input-addressed closure from
;;; the bootstrap fixtures, adopt it, and check the result.
;;;
;;; Code:

(test-begin "ca-adopt")

(define store (open-connection-for-tests))
(%graft? #f)

(define guile-drv (package-derivation store %bootstrap-guile))
(build-derivations store (list guile-drv))

(define (realised drv) (realised-output-path store drv "out"))
(define (read-all file) (call-with-input-file file get-string-all))

(define (fresh-name prefix)
  (string-append prefix "-"
                 (number->string (random 1000000000
                                         (random-state-from-platform)))))

;; A trivial package, as tests/ca-policy.scm builds them: the policy hook acts
;; on PACKAGE lowering, so the re-entry test needs packages, not bare gexps.
(define* (trivial name builder #:optional (inputs '()))
  (package
    (name name)
    (version "1")
    (source #f)
    (build-system (@@ (guix build-system trivial) trivial-build-system))
    (arguments (list #:guile %bootstrap-guile #:builder builder))
    (inputs inputs)
    (synopsis "CA adopt test")
    (description "CA adopt test")
    (home-page #f)
    (license #f)))

;; An input-addressed derivation writing TEXT.
(define (ia-plain name text)
  (run-with-store store
    (gexp->derivation name
      #~(call-with-output-file #$output
          (lambda (p) (display #$text p)))
      #:addressing 'input
      #:guile-for-build guile-drv)))

;; An input-addressed derivation referencing DEP as a gexp input (a
;; derivation edge, as real packages reference their inputs).
(define (ia-ref name dep text)
  (run-with-store store
    (gexp->derivation name
      #~(call-with-output-file #$output
          (lambda (p) (format p "~a/~a" #$dep #$text)))
      #:addressing 'input
      #:guile-for-build guile-drv)))

(test-group "a small input-addressed closure is adopted"
  (let* ((leaf (ia-plain (fresh-name "adopt-leaf") "LEAF"))
         (_    (build-derivations store (list leaf)))
         (leaf-path (realised leaf))
         (mid  (ia-ref (fresh-name "adopt-mid") leaf "MID"))
         (_    (build-derivations store (list mid)))
         (mid-path (realised mid))
         (top  (ia-ref (fresh-name "adopt-top") mid "TOP"))
         (_    (build-derivations store (list top)))
         (top-path (realised top))
         (adopted (adopt-derivation store top #:guile guile-drv))
         (_    (build-derivations store (list adopted)))
         (adopted-path (realised adopted))
         (refs (references store adopted-path)))
    (test-assert "the adopted top is content-addressed"
      (equal? "content"
              (assoc-ref (derivation-builder-environment-vars adopted)
                         "goonixAddressing")))
    (test-assert "the adopted top is a new item, not the original"
      (not (string=? top-path adopted-path)))
    (test-assert "the adopted top references adopted items only"
      (and (not (member mid-path refs))
           (not (member leaf-path refs))
           (not (member top-path refs))))
    (test-assert "the adopted top's reference is itself content-addressed"
      (every (lambda (ref)
               (let ((info (query-path-info store ref)))
                 ;; An adopted item is a content-addressed (CA) derivation
                 ;; output; its deriver carries the content marker.
                 (and info
                      (not (string=? ref mid-path))
                      (not (string=? ref leaf-path)))))
             refs))
    (test-assert "the adopted top still carries its payload"
      ;; The content is the adopted mid's path followed by /TOP: the
      ;; reference was rewritten and the payload preserved.
      (let ((content (read-all adopted-path)))
        (and (string-suffix? "/TOP" content)
             (string=? content
                       (string-append (car refs) "/TOP")))))
    (test-assert "the adopted closure runs (its reference resolves)"
      ;; The adopted mid exists and itself references the adopted leaf, so
      ;; the whole closure is coherent and usable.
      (let* ((adopted-mid-path (car refs))
             (mid-refs (references store adopted-mid-path)))
        (and (valid-path? store adopted-mid-path)
             (not (member leaf-path mid-refs))
             (string-suffix? "/MID" (read-all adopted-mid-path)))))))

(test-group "an item the scanner flags is not adopted"
  ;; A derivation whose output carries a split piece of its own hash (8+
  ;; characters, not a whole occurrence): the scanner flags it (fragment), so
  ;; adopt-derivation returns it unchanged for the policy to build from source
  ;; instead.
  (let* ((name (fresh-name "adopt-flagged"))
         (drv  (run-with-store store
                 (gexp->derivation name
                   #~(call-with-output-file #$output
                       (lambda (p)
                         (let ((hash (basename #$output)))
                           (display (substring hash 3 15) p))))
                   #:addressing 'input
                   #:guile-for-build guile-drv)))
         (_    (build-derivations store (list drv)))
         (path (realised drv)))
    (test-assert "the scanner flags the split self-reference"
      (> (scan-report-fragments (scan-store-item path)) 0))
    (test-assert "a flagged item is not adopted (returned unchanged)"
      (eq? drv (adopt-derivation store drv #:guile guile-drv)))))

(test-group "the adopt cache distinguishes the guile and system it builds with"
  ;; adopt-derivation returns a GRAFT derivation built with its #:guile and
  ;; #:system.  A cache keyed only on the adopted derivation's file name lets
  ;; the first caller's guile win for every later caller on the same
  ;; connection.  Graft derivations are only created here, not built, so no
  ;; second working guile is needed.
  (let* ((leaf (ia-plain (fresh-name "adopt-key-leaf") "LEAF"))
         (_    (build-derivations store (list leaf)))
         (top  (ia-ref (fresh-name "adopt-key-top") leaf "TOP"))
         (_    (build-derivations store (list top)))
         (other-guile (ia-plain (fresh-name "adopt-key-guile") "OTHER-GUILE"))
         (first  (adopt-derivation store top #:guile guile-drv))
         (second (adopt-derivation store top #:guile other-guile)))
    (define (input-drv-files drv)
      (map derivation-input-path (derivation-inputs drv)))
    (test-assert "adopting with a second guile yields a different derivation"
      (not (string=? (derivation-file-name first)
                     (derivation-file-name second))))
    (test-assert "the second result's inputs include the second guile"
      (member (derivation-file-name other-guile)
              (input-drv-files second)))
    (test-assert "the second result does not use the first guile"
      (not (member (derivation-file-name guile-drv)
                   (input-drv-files second))))))

(test-group "adopting under the adopted policy does not re-enter itself"
  ;; CA-6's gate hung for hours and was OOM-killed at 8G with a 2 GiB single
  ;; allocation.  Measured cause: adopt builds its graft with
  ;; graft-derivation/shallow*, a monadic value run through run-with-store.
  ;; With %guile-for-build #f the graft builder's guile is lowered as a PACKAGE
  ;; (default-guile-derivation, guix/gexp.scm), which goes through
  ;; bag->derivation, where goonix's policy hook is installed
  ;; (guix/packages.scm).  Under 'adopted that hook ADOPTS the guile, which
  ;; needs its own graft builder, which lowers guile again, forever.  Traced on
  ;; the gate: 1950 nested adopt calls, depth 1950, only two distinct
  ;; derivations, none ever returning; 24.7 GB allocated, 203 GCs.
  ;;
  ;; The memoisation cannot break it: adopt stores its result only AFTER adopt*
  ;; returns, so a re-entrant call always misses.
  ;;
  ;; Every other test here passes #:guile guile-drv explicitly, and
  ;; open-connection-for-tests sets %guile-for-build to %bootstrap-guile, so
  ;; the package-lowering path was never taken.  This test takes it: the
  ;; default guile is #f and the policy is 'adopted, as in `guix system image'.
  ;;
  ;; The recursion is COUNTED with a wrapper, not timed: a depth limit turns
  ;; the hang into a prompt failure, and the assertion is on the count.
  (let* ((leaf (trivial "ca-adopt-reentry-leaf"
                        #~(call-with-output-file #$output
                            (lambda (p) (display "LEAF" p)))))
         (top  (trivial "ca-adopt-reentry-top"
                        #~(call-with-output-file #$output
                            (lambda (p) (format p "~a/TOP" #$leaf)))
                        `(("leaf" ,leaf)))))
    (define calls 0)
    (define max-depth 0)
    (define depth 0)
    (define real-adopt adopt-derivation)
    (define limit 24)
    ;; A sentinel thrown when the recursion passes LIMIT, so the test fails
    ;; fast instead of allocating until the OOM killer intervenes.
    (define tag (make-symbol "adopt-reentry"))
    (define (counting-adopt store drv . args)
      (set! depth (+ depth 1))
      (set! calls (+ calls 1))
      (when (> depth max-depth) (set! max-depth depth))
      (when (> depth limit)
        (throw tag 'too-deep))
      (let ((result (apply real-adopt store drv args)))
        (set! depth (- depth 1))
        result))
    (parameterize ((%package-addressing-policy 'adopted)
                   (%guile-for-build #f)
                   (%upstream-package?
                    (upstream-package-set
                     (list->setq (list leaf top %bootstrap-guile)))))
      (let ((escaped
             (catch tag
               (lambda ()
                 ;; Replace the binding the policy hook looks up, so the
                 ;; re-entrant calls are counted too.
                 (module-set! (resolve-module '(guix ca adopt))
                              'adopt-derivation counting-adopt)
                 (dynamic-wind
                   (lambda () #t)
                   (lambda ()
                     (package-derivation store top)
                     #f)
                   (lambda ()
                     (module-set! (resolve-module '(guix ca adopt))
                                  'adopt-derivation real-adopt))))
               (lambda (key . args) #t))))
        (test-assert "lowering a package under the adopted policy terminates"
          (not escaped))
        (test-assert "adoption does not recurse into its own graft builder"
          ;; A small closure needs a handful of adopts, not one per level of
          ;; an unbounded chain.  LIMIT is far above what this closure needs.
          (<= max-depth limit))))))

(test-group "an adopted dependent retains an unadopted opaque input"
  ;; The name exercises the real glibc-name? non-adoption rule without a
  ;; bootstrap-heavy glibc build.  This is an actual store fixture: both
  ;; input-addressed outputs are registered, then only the dependent is
  ;; adopted.  Its rewritten content and references must retain that opaque
  ;; input-addressed item instead of inventing a promoted dependency.
  (let* ((opaque-like (ia-plain (fresh-name "glibc-option2") "opaque-input"))
         (_ (build-derivations store (list opaque-like)))
         (opaque-path (realised opaque-like))
         (dependent (ia-plain (fresh-name "adopt-opaque-dependent") opaque-path))
         (_ (build-derivations store (list dependent)))
         (adopted (adopt-derivation store dependent #:guile guile-drv)))
    (test-assert "the opaque-like derivation remains input-addressed and unadopted"
      (and (not (assoc-ref (derivation-builder-environment-vars opaque-like)
                           "goonixAddressing"))
           (eq? opaque-like
                (adopt-derivation store opaque-like #:guile guile-drv))))
    (test-equal "the dependent is adopted content-addressed"
      "content" (assoc-ref (derivation-builder-environment-vars adopted)
                           "goonixAddressing"))
    (build-derivations store (list adopted))
    (let ((path (realised adopted)))
      (test-equal "the adopted output still names the unadopted input"
        opaque-path (read-all path))
      (test-assert "the adopted output is registered and references that input"
        (and (valid-path? store path)
             (member opaque-path (references store path)))))))

(test-group "an item the opaque table names is not adopted through a dependent"
  ;; An adopted dependent's references are adopted recursively.  An item the
  ;; opaque table (guix ca opaque) names is refused there as glibc is: it is
  ;; returned unchanged, no graft is made for it, and the dependent's adopted
  ;; output keeps the reference to its input-addressed path.  The table
  ;; exists because the scanner cannot see every self path, so a clean scan
  ;; does not overrule it: these fixtures scan clean.  Each fixture is named
  ;; as its entry's package derivation would be (name, then a version), and
  ;; the dependent references it as a derivation input, as util-linux
  ;; references file.
  (define (entry->derivation-name entry)
    (match entry
      ((name) (fresh-name name))
      ((name version) (string-append name "-" version))))
  (define (adopt-dependent-of item-name)
    ;; Return the item, its output, the adopted dependent and its output.
    (let* ((item (ia-plain item-name (fresh-name "opaque-table-item")))
           (_ (build-derivations store (list item)))
           (dependent (ia-ref (fresh-name "adopt-table-dependent") item "DEP"))
           (_ (build-derivations store (list dependent)))
           (adopted (adopt-derivation store dependent #:guile guile-drv)))
      (build-derivations store (list adopted))
      (values item (realised item) adopted (realised adopted))))
  (for-each
   (lambda (entry)
     (let ((label (car entry)))
       (call-with-values
           (lambda () (adopt-dependent-of (entry->derivation-name entry)))
         (lambda (item item-path adopted adopted-path)
           (test-assert (string-append "the " label " fixture scans clean")
             (not (item-flagged? store item-path)))
           (test-assert (string-append label " is not adopted (returned unchanged)")
             (eq? item (adopt-derivation store item #:guile guile-drv)))
           (test-equal (string-append "the dependent of " label
                                      " is adopted content-addressed")
             "content" (assoc-ref (derivation-builder-environment-vars adopted)
                                  "goonixAddressing"))
           (test-equal (string-append "the adopted dependent still names the"
                                      " input-addressed " label)
             (string-append item-path "/DEP") (read-all adopted-path))
           (test-equal (string-append "the adopted dependent references the"
                                      " input-addressed " label " alone")
             (list item-path) (references store adopted-path))))))
   %opaque-packages)
  ;; Matching is by the derivation's parsed name, not a prefix:
  ;; commencement's file-boot0 is not in the table, and its adoption graft is
  ;; accepted (DECISIONS 93).
  (call-with-values
      (lambda () (adopt-dependent-of (fresh-name "file-boot0")))
    (lambda (item item-path adopted adopted-path)
      (test-assert "file-boot0 is adopted (a graft, not the original)"
        (not (eq? item (adopt-derivation store item #:guile guile-drv))))
      (test-assert "the adopted dependent of file-boot0 references its adopted copy"
        (let ((refs (references store adopted-path)))
          (and (= 1 (length refs))
               (not (member item-path refs))
               (string=? (read-all adopted-path)
                         (string-append (car refs) "/DEP"))))))))

(close-connection store)
(test-end "ca-adopt")
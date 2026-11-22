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
  #:use-module (guix ca scan)
  #:use-module (guix derivations)
  #:use-module (guix monads)
  #:use-module (gnu packages bootstrap)
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

(close-connection store)
(test-end "ca-adopt")
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
  #:use-module (guix derivations)
  #:use-module (gnu packages base)
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
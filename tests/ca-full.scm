;;; goonix: CA-8 full policy — addressing, opaque marking, name reproduction.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (test-ca-full)
  #:use-module (guix)
  #:use-module (guix tests)
  #:use-module (guix ca)
  #:use-module (guix ca policy)
  #:use-module (guix sets)
  #:use-module (guix derivations)
  #:use-module (guix gexp)
  #:use-module (guix build-system trivial)
  #:use-module (gnu packages bootstrap)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-64))

;;; Commentary:
;;;
;;; CA-8's gate is "The world builds; every opaque package is marked; a second
;;; machine reproduces the names."  The world build is a build-farm job, not
;;; feasible here (STATUS.md records this).  The two testable parts:
;;;
;;; - the full policy lowers an unmarked package content-addressed and an
;;;   opaque package (properties '((self-references . opaque))) resolved-
;;;   addressed, and the opaque package's dependent still embeds its realised
;;;   path;
;;; - a second independent store connection reproduces the same content-
;;;   addressed derivation NAME for the same package graph: the name is a pure
;;;   function of the resolved graph, not of the store that builds it.
;;;
;;; Code:

(test-begin "ca-full")
(define store (open-connection-for-tests))
(%graft? #f)

(define (addressing drv)
  (assoc-ref (derivation-builder-environment-vars drv) "goonixAddressing"))

(define* (trivial name builder #:optional (inputs '()) (properties '()))
  (package
    (name name)
    (version "1")
    (source #f)
    (build-system trivial-build-system)
    (arguments (list #:guile %bootstrap-guile #:builder builder))
    (inputs inputs)
    (properties properties)
    (synopsis "CA full test")
    (description "CA full test")
    (home-page #f)
    (license #f)))

(define leaf
  (trivial "ca-full-leaf"
           #~(call-with-output-file #$output
               (lambda (port) (display "LEAF\n" port)))))

(define mid
  (trivial "ca-full-mid"
           #~(call-with-output-file #$output
               (lambda (port) (format p "~a/MID\n" #$leaf)))
           `(("leaf" ,leaf))))

(define opaque
  (trivial "ca-full-opaque"
           #~(call-with-output-file #$output
               (lambda (port) (display "OPAQUE\n" port)))
           '() '((self-references . opaque))))

(define on-opaque
  (trivial "ca-full-on-opaque"
           #~(call-with-output-file #$output
               (lambda (port) (format port "~a/ON\n" #$opaque)))
           `(("opaque" ,opaque))))

(test-group "the full policy addresses unmarked content and opaque resolved"
  (parameterize ((%package-addressing-policy 'full))
    (test-equal "an unmarked package is content-addressed under full"
      "content" (addressing (package-derivation store leaf)))
    (test-equal "an unmarked dependent is content-addressed under full"
      "content" (addressing (package-derivation store mid)))
    (test-equal "an opaque package is resolved-addressed under full"
      "resolved" (addressing (package-derivation store opaque)))
    (test-equal "a dependent on an opaque input is content-addressed"
      "content" (addressing (package-derivation store on-opaque)))))

(test-group "an opaque package's dependent embeds its realised path"
  (parameterize ((%package-addressing-policy 'full))
    (let* ((opaque-drv (package-derivation store opaque))
           (on-drv (package-derivation store on-opaque)))
      (build-derivations store (list opaque-drv on-drv))
      (let ((opaque-out (realised-output-path store opaque-drv "out"))
            (on-out (realised-output-path store on-drv "out")))
        (test-assert "the dependent's output refers to the opaque realised path"
          (member opaque-out (references store on-out)))
        (test-assert "the dependent embeds the opaque realised path in its text"
          (string-contains
           (call-with-input-file on-out get-string-all)
           opaque-out))))))

(test-group "a second connection reproduces the content-addressed names"
  ;; The name is a pure function of the resolved graph: lowering the same
  ;; package graph under the full policy on two independent connections yields
  ;; the same derivation file name (and the same content-addressed output name).
  (let ((second (open-connection-for-tests)))
    (parameterize ((%package-addressing-policy 'full))
      (let ((drv1 (package-derivation store mid))
            (drv2 (package-derivation second mid)))
        (test-equal "the same derivation name on both connections"
          (derivation-file-name drv1)
          (derivation-file-name drv2))
        (test-equal "the same content-addressed output name on both connections"
          (derivation->output-path drv1)
          (derivation->output-path drv2))
        (test-equal "the addressing marker matches on both connections"
          (addressing drv1) (addressing drv2))))
    (close-connection second)))

(test-end "ca-full")
;;; goonix: replacing packages at the moment they are lowered.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (guix package-overrides)
  #:use-module (guix monads)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (%package-overrides
            package-override-key
            overridable))

;;; Commentary:
;;;
;;; An override replaces one package object by another wherever the first
;;; is lowered: as an input of any package, at any depth, and where a gexp
;;; or a service refers to it.  No package is copied or rewritten ahead of
;;; time; the list is consulted when a package becomes a derivation.
;;;
;;; While a replacement is lowered, whatever it replaces stays itself, so a
;;; replacement can be built on top of its original.  That holds however
;;; the replacement is reached, through its original or by name.
;;;
;;; (guix packages) has three hooks for this: the procedures that lower a
;;; package are passed through 'overridable', and the key under which each
;;; caches its result includes 'package-override-key'.
;;;
;;; Code:

(define %package-overrides
  ;; A list of (ORIGINAL . REPLACEMENT) pairs of packages.  ORIGINAL is
  ;; compared with 'eq?' and the first pair that has it wins.  The empty
  ;; list, which is the default, means that lowering is what it is without
  ;; this module.
  (make-parameter '()))

(define %override-keys
  ;; Lists of overrides -> small integers, so that the key of a cached
  ;; derivation need not hold package objects.
  (make-weak-key-hash-table))

(define %next-key 0)

(define (package-override-key)
  "Return what tells the overrides in effect from any others, for the key
under which a derivation is cached: #f when there are none."
  (match (%package-overrides)
    (() #f)
    (overrides
     (or (hashq-ref %override-keys overrides)
         (begin
           (set! %next-key (+ 1 %next-key))
           (hashq-set! %override-keys overrides %next-key)
           %next-key)))))

(define %exemptions
  ;; Lists of overrides -> alists of a replacement and the list without
  ;; the pairs that lead to it, so that lowering one replacement twice
  ;; under the same overrides finds the same list, hence the same key.
  (make-weak-key-hash-table))

(define (without-pairs-to replacement overrides)
  "Return OVERRIDES without the pairs whose replacement is REPLACEMENT; the
same list each time for the same arguments, and OVERRIDES itself when it has
no such pair."
  (if (any (match-lambda
             ((_ . candidate) (eq? candidate replacement)))
           overrides)
      (let ((known (or (hashq-ref %exemptions overrides) '())))
        (or (assq-ref known replacement)
            (let ((rest (remove (match-lambda
                                  ((_ . candidate)
                                   (eq? candidate replacement)))
                                overrides)))
              (hashq-set! %exemptions overrides
                          (alist-cons replacement rest known))
              rest)))
      overrides))

(define (overridable lower)
  "Return a procedure like LOWER, which takes a package and more arguments
and returns its derivation in the store monad, that heeds
'%package-overrides'."
  (lambda (package . arguments)
    (match (%package-overrides)
      (()
       (apply lower package arguments))
      (overrides
       (let* ((package (match (assq package overrides)
                         (#f package)
                         ((_ . replacement) replacement)))
              (rest    (without-pairs-to package overrides)))
         (if (eq? rest overrides)
             (apply lower package arguments)
             (state-parameterize ((%package-overrides rest))
               (apply lower package arguments))))))))

;;; package-overrides.scm ends here

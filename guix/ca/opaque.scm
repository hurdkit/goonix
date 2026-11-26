;;; goonix: the table of opaque packages (self-references that cannot be
;;; rewritten), applied at lowering exactly as the opaque property is.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (guix ca opaque)
  #:use-module (guix packages)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (%opaque-packages
            opaque-name?
            opaque-package?
            opaque-package-names))

;;; Commentary:
;;;
;;; Plan section 4.3: a package whose binary carries a self-reference that
;;; cannot be rewritten is refused — it gets the opaque property, or the
;;; derivation #:addressing 'resolved, and is built at its final path like
;;; today.  gnu/packages is never edited, so the marking comes from this
;;; goonix table: it lists packages by name (and by version where a name alone
;;; is too broad), and the policy applies it at lowering exactly as the opaque
;;; property is applied.
;;;
;;; The table starts from `guix ca scan`'s result on this store: glibc,
;;; qemu-minimal and file (plan section 4.3).
;;;
;;; Adoption (guix ca adopt) applies the same table to the items it reaches
;;; through an adopted dependent's references, by derivation name: an item
;;; the table names is not adopted, and the dependent keeps its reference to
;;; the item's input-addressed path.  Both callers go through opaque-name?,
;;; which needs no package, so the table stays the one source.
;;;
;;; Refreshing the table: re-run `guix ca scan` over the store and add the
;;; packages it flags; and from a build farm, the `--check=relocation` results
;;; of plan section 4.4 (build twice with two different tokens and compare) —
;;; a package that fails is marked opaque.  Scanning cannot see a self path
;;; that is hashed, encrypted, encoded, cut short, or used to compute
;;; something; the relocation check is the sound test for those.
;;;
;;; Code:

(define %opaque-packages
  ;; Each entry is (NAME) or (NAME VERSION): a package matches when its name
  ;; is NAME and, if a version is given, its version is that version.
  '(("glibc")
    ("qemu-minimal")
    ("file")))

(define (opaque-package-names)
  "Return the names in the opaque table."
  (map car %opaque-packages))

(define (opaque-name? name version)
  "Whether the opaque table names NAME at VERSION: an entry (NAME) matches
every version, an entry (NAME V) only version V.  VERSION may be #f (a name
with no version part), which only an entry without a version matches.

This is the table's one test.  opaque-package? applies it to a package's name
and version, and (guix ca adopt) to a derivation's name split into the two.
It takes no package, so adoption can use it on derivations alone."
  (any (match-lambda
         ((n) (string=? n name))
         ((n v) (and version (string=? n name) (string=? v version))))
       %opaque-packages))

(define (opaque-package? package)
  "Whether PACKAGE is marked opaque: either it carries the opaque
self-references property, or the goonix opaque table names it (by name, and
by version where the entry gives one).  The policy applies this at lowering
exactly as the opaque property alone was applied."
  (or (eq? 'opaque (assq-ref (package-properties package) 'self-references))
      (opaque-name? (package-name package) (package-version package))))

;;; opaque.scm ends here
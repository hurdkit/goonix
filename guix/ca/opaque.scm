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

(define (opaque-package? package)
  "Whether PACKAGE is marked opaque: either it carries the opaque
self-references property, or the goonix opaque table names it (by name, and
by version where the entry gives one).  The policy applies this at lowering
exactly as the opaque property alone was applied."
  (or (eq? 'opaque (assq-ref (package-properties package) 'self-references))
      (let ((name (package-name package))
            (version (package-version package)))
        (any (match-lambda
               ((n) (string=? n name))
               ((n v) (and (string=? n name) (string=? v version))))
             %opaque-packages))))

;;; opaque.scm ends here
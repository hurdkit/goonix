;;; goonix: host side of content-addressed grafts.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (guix ca graft)
  #:use-module (guix derivations)
  #:use-module (guix store)
  #:use-module ((guix ca) #:select (placeholder-path? token-store-path?))
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-71)
  #:export (%graft-content-addressed?
            goonix-graft-modules
            goonix-graft-procedure
            goonix-graft-load
            goonix-graft-addressing
            goonix-unrealised-outputs
            goonix-realised-output-path
            goonix-references-of-realised
            goonix-reference-origins
            goonix-reference-origins*
            goonix-non-self-references
            goonix-graft-origin
            goonix-graft-origin-realised))

;;; Commentary:
;;;
;;; A graft of a content-addressed derivation writes its own outputs at
;;; self-tokens (the reserved "eout" alphabet).  Upstream's graft builder
;;; cannot rewrite those: its rewriter only accepts nix-base32 hashes.  Such
;;; a graft therefore imports (guix ca build graft) and calls
;;; graft/content-addressed, which applies the graft through upstream's
;;; rewriter in two passes.
;;;
;;; The three helpers below are substituted into upstream's build gexp in
;;; guix/grafts.scm (marked goonix:).  For an input-addressed DRV they return
;;; the module list unchanged, the plain 'graft' symbol and an empty load
;;; list, so the builder text and the module list — and hence the derivation
;;; — are exactly upstream's.  This module lives outside guix/build so that
;;; no upstream build module imports it.
;;;
;;; Code:

(define %graft-content-addressed?
  ;; Whether grafts are forced content-addressed even over an input-addressed
  ;; derivation.  Adoption (guix ca adopt) sets this: an adopted item is a
  ;; content-addressed graft of an upstream input-addressed binary.  Off by
  ;; default, so an ordinary input-addressed graft stays exactly upstream's.
  (make-parameter #f))

(define (content-addressed-graft? drv)
  "Whether grafting DRV writes content-addressing self-tokens.  Either DRV is
not input-addressed — it carries a goonixAddressing marker — so the graft
derivation over it is content-addressed; or %graft-content-addressed? forces
it (adoption).  (The marker, not the output path, is the test: on the host a
content-addressed derivation's output path is a placeholder, and the
self-token only appears in the builder's environment.)"
  (or (%graft-content-addressed?)
      (and (assoc-ref (derivation-builder-environment-vars drv)
                      "goonixAddressing")
           #t)))

(define (goonix-graft-modules drv modules)
  "Return MODULES, the import list of a graft builder for DRV: unchanged for
an input-addressed DRV, with (guix ca build graft) appended for a
content-addressed one."
  (if (content-addressed-graft? drv)
      (append modules '((guix ca build graft)))
      modules))

(define (goonix-graft-procedure drv)
  "Return the graft procedure a graft builder for DRV calls: the plain
'graft' symbol for an input-addressed DRV (so the gexp text is upstream's),
'graft/content-addressed' for a content-addressed one."
  (if (content-addressed-graft? drv)
      'graft/content-addressed
      'graft))

(define (goonix-graft-load drv)
  "Return the list of forms that load the content-addressed graft module
into a graft builder for DRV: the empty list for an input-addressed DRV (so
the builder text is exactly upstream's — spliced with #+@, an empty list adds
no form), a use-modules form for a content-addressed one.  The module is
imported by goonix-graft-modules but must also be loaded before
graft/content-addressed is called."
  (if (content-addressed-graft? drv)
      '((use-modules (guix ca build graft)))
      '()))

(define (goonix-graft-addressing drv)
  "Return the #:addressing argument for a graft derivation over DRV: 'content
when the graft writes self-tokens (DRV is content-addressed, or adoption
forces it), otherwise #f so the graft's addressing is decided as upstream's
is.  Returning #f keeps an input-addressed graft's derivation upstream's."
  (and (content-addressed-graft? drv) 'content))

(define (reserved-path? path)
  "Whether PATH is a goonix reserved name: a placeholder (not yet built) or a
self token (the builder's own output).  Neither is a store item, so the
daemon refuses operations on it."
  (or (placeholder-path? path) (token-store-path? path)))

(define (goonix-unrealised-outputs drv outputs)
  "Return the OUTPUTS of DRV whose paths are reserved names, or #f when none
is.  A content-addressed or resolved package's outputs are placeholders
until the daemon finalises them, so a graft computed at lowering time sees
reserved paths.  Upstream's non-self-references would query their
references; the daemon refuses reserved paths and drops the connection.
This predicate lets the caller take the goonix path instead."
  (let ((reserved (filter (lambda (output)
                            (reserved-path?
                             (derivation->output-path drv output)))
                          outputs)))
    (and (pair? reserved) reserved)))

(define (goonix-realised-output-path store drv output)
  "Return the realised path of DRV's OUTPUT, or #f when it cannot be known
without building.  A reserved output is asked of the daemon by DERIVATION
FILE NAME and output name, never by its placeholder path."
  (let ((path (derivation->output-path drv output)))
    (if (reserved-path? path)
        (false-if-exception
         (realised-output-path store drv output))
        path)))

(define (goonix-references-of-realised store drv outputs)
  "Return the references of the OUTPUTS of DRV, realising DRV first when any
output is a reserved name.

Upstream's rule is kept: graft only what the output really refers to.  An
unrealised placeholder has no readable references, so DRV is BUILT, exactly
as upstream's build-on-missing fallback does.  The build request names the
.drv file, never a placeholder.  The references are then read from each
output's REALISED path.

If the build fails, this returns the conservative superset: every realised
output of every input derivation, so no graft is dropped.  That may produce
a grafted variant that was not strictly needed; it never leaves a package
ungrafted."
  (define (input-output-paths drv)
    (append-map (lambda (input)
                  (let ((input-drv (derivation-input-derivation input)))
                    (filter-map
                     (lambda (output)
                       (goonix-realised-output-path store input-drv output))
                     (derivation-input-sub-derivations input))))
                (derivation-inputs drv)))
  (if (goonix-unrealised-outputs drv outputs)
      (if (false-if-exception (build-derivations store (list drv)))
          (append-map
           (lambda (output)
             (let ((path (goonix-realised-output-path store drv output)))
               (if (and path (not (reserved-path? path)))
                   (references/cached store path)
                   '())))
           outputs)
          (input-output-paths drv))
      (append-map (lambda (output)
                    (references/cached store
                                       (derivation->output-path drv output)))
                  outputs)))

(define (goonix-reference-origins store drv items)
  "Like reference-origins, but resolving each derivation's outputs against
their REALISED paths.  ITEMS are realised store paths, while a
content-addressed derivation's declared output path is a placeholder, so
upstream's lookup would match nothing and silently drop every graft."
  (define (lookup-derivers drv result items)
    (let scan ((outputs (derivation-output-names drv))
               (result result)
               (items items))
      (match outputs
        (()
         (values result items))
        ((output . rest)
         (let ((file (goonix-realised-output-path store drv output)))
           (if (and file (member file items))
               (scan rest
                     (alist-cons drv output result)
                     (delete file items))
               (scan rest result items)))))))
  (let loop ((drvs (list drv))
             (items items)
             (result '())
             (visited '()))
    (match drvs
      (()
       result)
      ((drv . rest)
       (cond ((null? items)
              result)
             ((memq drv visited)
              (loop rest items result visited))
             (else
              (let ((result items (lookup-derivers drv result items)))
                (loop (append rest
                              (map derivation-input-derivation
                                   (derivation-inputs drv)))
                      items result
                      (cons drv visited)))))))))

;; lookup-derivers returns two values; srfi-71's let above binds them.

(define (goonix-graft-origin-realised store origin output)
  "Return the realised output path of a graft's ORIGIN and OUTPUT.  ORIGIN
may be a derivation whose declared output is a placeholder, or a plain
store item.  DEPS in cumulative-grafts are realised paths, so the comparison
that selects the applicable grafts must use this rather than the declared
path.  The fields are passed in rather than the graft record, so this module
does not import (guix grafts), which imports it."
  (if (derivation? origin)
      (or (goonix-realised-output-path store origin output)
          (derivation->output-path origin output))
      origin))

(define (goonix-non-self-references store drv outputs)
  "Return the references of DRV's OUTPUTS with self references removed, or
#f when no output is reserved so the caller uses upstream's expression.

Upstream's rule is kept: graft only what the output really refers to.  A
reserved output cannot be queried, so DRV is BUILT by its .drv file name
(as upstream's build-on-missing fallback does) and the references are read
from the REALISED outputs."
  (and (goonix-unrealised-outputs drv outputs)
       (let ((refs (goonix-references-of-realised store drv outputs))
             (self (filter-map
                    (lambda (output)
                      (goonix-realised-output-path store drv output))
                    outputs)))
         (remove (lambda (ref) (member ref self)) refs))))

(define (goonix-reference-origins* store drv items)
  "Like goonix-reference-origins, but return #f when none of DRV's outputs is
reserved, so the caller falls back to upstream's reference-origins."
  (and (goonix-unrealised-outputs drv (derivation-output-names drv))
       (goonix-reference-origins store drv items)))

(define (goonix-graft-origin store drv outputs origin output)
  "Return the origin's REALISED output path when DRV's OUTPUTS are reserved,
or #f so the caller falls back to upstream's graft-origin-file-name.  ORIGIN
and OUTPUT are the graft's fields, passed by the caller: they are record
macros in (guix grafts), so they cannot be looked up here, and that module
imports this one."
  (and (goonix-unrealised-outputs drv outputs)
       (goonix-graft-origin-realised store origin output)))

;;; graft.scm ends here
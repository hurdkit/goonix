;;; goonix: adoption — upstream binaries renamed to content-addressed items.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (guix ca adopt)
  #:use-module (guix derivations)
  #:use-module (guix monads)
  #:use-module (guix store)
  #:use-module (guix grafts)
  #:use-module ((guix utils) #:select (%current-system))
  #:use-module (guix ca graft)
  #:use-module (guix ca scan)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (adopt-derivation
            adopted-item?
            item-flagged?))

;;; Commentary:
;;;
;;; Adoption reuses the graft rewriter as an ordinary content-addressed
;;; derivation: adopt(P), for an upstream package P whose input-addressed
;;; derivation is D, is a content-addressed graft of D's outputs.  The
;;; mapping sends each reference R of D's outputs to adopt(R)'s output, and
;;; each old output to its own output (the self-token the daemon finalises).
;;; The recursion over references is the one guix/grafts.scm does for
;;; cumulative grafts — build or substitute D, query its references, recurse,
;;; memoise per item — through its exported pieces (non-self-references,
;;; reference-origins, graft-derivation/shallow), not copied.
;;;
;;; An item the scanner flags (a split, UTF-16 or hidden self-reference, or a
;;; self-referencing name or link), and glibc, is not adopted: its package is
;;; lowered content-addressed from source instead (see guix/ca/policy).
;;;
;;; Code:

(define (item-flagged? store path)
  "Whether the store item at PATH is flagged by the scanner: it carries a
self-reference the rewriter cannot provably reverse (a fragment, a UTF-16
encoding, a hidden archive member, or a self-referencing name or link).  A
whole plain self-reference is rewritable and does not flag the item."
  (let ((report (scan-store-item path)))
    (or (> (scan-report-fragments report) 0)
        (> (scan-report-utf16 report) 0)
        (> (scan-report-hidden report) 0)
        (> (scan-report-names report) 0)
        (> (scan-report-links report) 0))))

(define (glibc-derivation? drv)
  "Whether DRV builds glibc, which must be built from source in adopted mode
rather than adopted (its self-references are not all rewritable)."
  (string-prefix? "glibc" (derivation-name drv)))

(define (adopted-item? store drv)
  "Whether DRV's output can be adopted: it is not glibc and the scanner does
not flag it.  DRV's output must already be realised, except for glibc, which
is refused by name and whose contents are therefore never read."
  (and (not (glibc-derivation? drv))
       (not (item-flagged? store (realised-output-path store drv "out")))))

(define graft-derivation/shallow*
  (store-lower graft-derivation/shallow))

(define* (adopt-derivation store drv
                           #:key (guile (%guile-for-build))
                           (system (%current-system)))
  "Adopt DRV, an upstream input-addressed derivation: return a
content-addressed derivation whose output is DRV's tree with every store
reference rewritten to its adopted counterpart and its own path rewritten to
the content address.  References are adopted recursively, memoised per item;
an item the scanner flags, and glibc, is built content-addressed from source
instead of adopted (its derivation is returned unchanged for the policy to
re-lower).  The rewrite goes through graft-derivation/shallow under
%graft-content-addressed?, so it is the two-pass content-addressed graft."
  (define cache (make-hash-table))
  (define (adopt drv)
    (let ((key (derivation-file-name drv)))
      (or (hash-ref cache key)
          (let ((result (adopt* drv)))
            (hash-set! cache key result)
            result))))
  (define (adopt* drv)
    ;; Realise EVERY output of DRV before it is scanned or grafted.  A
    ;; multi-output package referenced through one output (gcc:lib, glib:bin,
    ;; any :debug output) has its other outputs absent from the store until
    ;; now: adopted-item? and non-self-references read them, and the graft
    ;; over all outputs needs them present.  (derivation-input drv) defaults
    ;; to every output, so substitutes are used; upstream does the same when
    ;; lowering needs an item's contents (references-oracle, guix/grafts.scm).
    ;; glibc is the one case that needs no contents: it is re-lowered from
    ;; source, so its input-addressed outputs are not fetched for that.
    (unless (glibc-derivation? drv)
      (build-derivations store (list (derivation-input drv))))
    (cond
     ;; Flagged items and glibc are not adopted; the policy re-lowers them
     ;; content-addressed from source.  Here we return the derivation itself.
     ((not (adopted-item? store drv)) drv)
     (else
      (let* ((outputs (derivation-output-names drv))
             (refs (non-self-references store drv outputs))
             (origins (reference-origins drv refs))
             ;; Adopt each reference's deriver, memoised.
             (adopted-origins
              (map (match-lambda
                     ((origin . output)
                      (cons (cons origin output)
                            (adopt origin))))
                   origins))
             (grafts
              (filter-map
               (match-lambda
                 (((origin . output) . adopted)
                  ;; Only graft references that actually changed (were
                  ;; adopted); an unchanged deriver needs no graft.
                  (and (not (eq? origin adopted))
                       (graft (origin origin)
                              (origin-output output)
                              (replacement adopted)
                              (replacement-output output)))))
               adopted-origins)))
        (if (null? grafts)
            ;; No reference changed: adopt DRV's own output alone (a self
            ;; graft), so its path still becomes the content address.
            (parameterize ((%graft-content-addressed? #t)
                           (%graft-with-utf8-locale? #f))
              (graft-derivation/shallow* store drv
                                         (list (graft (origin drv)
                                                      (replacement drv)))
                                         #:guile guile #:system system))
            (parameterize ((%graft-content-addressed? #t)
                           (%graft-with-utf8-locale? #f))
              (graft-derivation/shallow* store drv grafts
                                         #:guile guile #:system system)))))))
  ;; Build or substitute DRV first so its references can be queried.
  (build-derivations store (list drv))
  (adopt drv))

;;; adopt.scm ends here
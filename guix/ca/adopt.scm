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

;; Memoisation ACROSS calls, per store connection.
;;
;; The 'adopted policy calls adopt-derivation for EVERY package it lowers
;; (guix/ca/policy.scm, adopt-lowered-derivation).  A cache made inside each
;; call therefore memoises nothing across packages: each one re-adopted, and
;; item-flagged? rescanned, its whole reference closure.  On the CA-6 boot
;; gate that was O(packages x closure): the client read 165.9 GB from a
;; 6.05 GB store (~27 passes, all page cache) with the daemon idle, and gcc
;; came round once per package.
;;
;; Two caches, both keyed by the store CONNECTION's SOCKET so the tests'
;; separate daemons never share results:
;;   %adopt-caches: socket -> (derivation file name -> adopted derivation)
;;   %scan-caches:  socket -> (realised store path -> flagged?)
;; The scan cache is sound because a store item never changes once valid.
;;
;; The key is the SOCKET, not the <store-connection> record: upstream warns
;; at guix/store.scm's build-accumulator that "cache-object-mapping and
;; similar functional setters change the store's object identity", so two
;; lowerings on one connection pass DIFFERENT record objects.  Keying on the
;; record made every lookup miss (measured: a shared dependency was scanned
;; once per lowering even with the cache in place).  The socket is the
;; connection's stable identity, as upstream's own eq? test there uses.
;; Weak keys let a closed connection's tables be collected.
;;
;; The adopt cache keeps upstream's derivation OBJECTS alive, and the callers
;; compare cached results with eq?: (eq? adopt d) in guix/ca/policy.scm decides
;; whether to re-lower from source, and (eq? origin adopted) here decides
;; whether a reference changed.  That stays correct across calls because
;; upstream's derivation and read-derivation-from-file return the object held
;; in %derivation-cache (guix/derivations.scm, "Preserve pointer equality"),
;; so the same .drv always yields the same object while this cache holds it.
;;
;; The key includes the SYSTEM and the GUILE derivation's file name as well as
;; the adopted derivation's: the graft derivation returned is BUILT with those
;; two (graft-derivation/shallow* ... #:guile guile #:system system), so keying
;; on the derivation alone would let the first caller's guile and system win
;; for every later caller.  A per-call cache could not show this; a cache that
;; outlives the call can.
(define %adopt-caches (make-weak-key-hash-table))
(define %scan-caches (make-weak-key-hash-table))

(define (connection-cache caches store)
  "Return the table for STORE's connection in CACHES, creating it on first
use.  Keyed by the connection's socket, which is stable across the record
copies that the store monad's functional setters make."
  (let ((key (store-connection-socket store)))
    (or (hashq-ref caches key)
        (let ((table (make-hash-table)))
          (hashq-set! caches key table)
          table))))

(define (item-flagged? store path)
  "Whether the store item at PATH is flagged by the scanner: it carries a
self-reference the rewriter cannot provably reverse (a fragment, a UTF-16
encoding, a hidden archive member, or a self-referencing name or link).  A
whole plain self-reference is rewritable and does not flag the item.

The answer is memoised per store connection and per realised PATH: a valid
store item never changes, so it is scanned at most once per connection."
  (let ((cache (connection-cache %scan-caches store)))
    (let ((cached (hash-ref cache path 'unset)))
      (if (not (eq? cached 'unset))
          cached
          (let ((flagged
                 (let ((report (scan-store-item path)))
                   (or (> (scan-report-fragments report) 0)
                       (> (scan-report-utf16 report) 0)
                       (> (scan-report-hidden report) 0)
                       (> (scan-report-names report) 0)
                       (> (scan-report-links report) 0)))))
            (hash-set! cache path flagged)
            flagged)))))

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
the content address.  References are adopted recursively; an item the scanner
flags, and glibc, is built content-addressed from source instead of adopted
(its derivation is returned unchanged for the policy to re-lower).  The
rewrite goes through graft-derivation/shallow under
%graft-content-addressed?, so it is the two-pass content-addressed graft.

Results are memoised ACROSS calls in %adopt-caches, keyed by the store
connection and then by derivation file name, because the 'adopted policy
calls this for every package it lowers: a per-call cache would re-adopt and
rescan the whole closure once per package.  The scan reports are memoised
separately in item-flagged?."
  (define cache (connection-cache %adopt-caches store))
  (define (adopt drv)
    ;; The key carries the system and the guile derivation as well as DRV:
    ;; the graft returned is built with them, so a key of DRV alone would
    ;; serve the first caller's guile and system to every later caller.
    (let ((key (list system
                     (and (derivation? guile) (derivation-file-name guile))
                     (derivation-file-name drv))))
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
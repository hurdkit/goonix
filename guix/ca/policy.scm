;;; goonix: package and derivation addressing policy for mixed Guix.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (guix ca policy)
  #:use-module (guix monads)
  #:use-module (guix store)
  #:use-module (guix packages)
  #:use-module (guix sets)
  #:use-module (guix build-system)
  #:use-module (guix utils)
  #:use-module (guix derivations)
  #:use-module (guix ca)
  #:use-module (guix ca opaque)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (%package-addressing-policy
            %upstream-package?
            upstream-package?
            %package-addressing
            upstream-package-set
            package-addressing
            adopt-package?
            package-addressing-key
            lower-bag-with-addressing
            gexp-with-addressing
            gexp-addressing))

;;; Commentary:
;;;
;;; The package mark selects only the requested kind for that package's own
;;; bag-named gexp.  Nested derivations do not inherit it.  The final kind is
;;; chosen after gexp inputs and reference lists have been lowered: under
;;; mixed an input-addressed request whose inputs are not all input-addressed
;;; becomes content-addressed.  A placeholder in a reference list has the same
;;; effect, even when the object is not a derivation input.  Thus origins,
;;; computed files, graphs, profiles and packages obey the same rule.

(define %package-addressing-policy
  (make-parameter 'input))

(define %guix-source-tree
  (dirname (dirname (search-path %load-path "guix/packages.scm"))))

(define %upstream-source-file?
  (let ((cache (make-hash-table)))
    (lambda (file)
      (let ((handle (hash-get-handle cache file)))
        (if handle
            (cdr handle)
            (let* ((absolute
                    (if (absolute-file-name? file)
                        file
                        (string-append %guix-source-tree "/" file)))
                   (gnu (string-append %guix-source-tree "/gnu/"))
                   (guix (string-append %guix-source-tree "/guix/"))
                   (result
                    (and (or (string-prefix? gnu absolute)
                             (string-prefix? guix absolute))
                         (file-exists? absolute))))
              (hash-set! cache file result)
              result))))))

(define (upstream-package? package)
  "Whether PACKAGE was defined in the running Guix's guix/ or gnu/ tree."
  (let ((location (package-location package)))
    (and location (%upstream-source-file? (location-file location)))))

(define %upstream-package?
  ;; Location marks upstream definitions, including runtime-generated ones;
  ;; inherited records receive their new definition's location.
  (make-parameter upstream-package?))

(define %package-addressing
  (make-parameter 'input))

(define %package-derivation-name
  (make-parameter #f))

(define (upstream-package-set packages)
  "Return a predicate marking precisely the package objects in PACKAGES."
  (lambda (package)
    (set-contains? packages package)))

(define (package-addressing package)
  "Return the kind to request for PACKAGE's own derivation."
  (cond ((and (opaque-package? package)
              (memq (%package-addressing-policy) '(content full adopted)))
         ;; goonix: the opaque table forces resolved-addressing under the
         ;; content/full policies, and under 'adopted too.  Under mixed/input
         ;; the upstream graph is kept byte-identical (an input-addressed
         ;; dependent may not take a resolved dependency), so only the
         ;; explicit opaque property — upstream's own marking — applies there.
         ;;
         ;; An opaque package must be marked BEFORE it is built: a self
         ;; reference that a rewrite cannot reverse is discovered by the
         ;; scanner only after the item exists, and refusing it then costs the
         ;; whole build.  Dependents of such an item are promoted out of input
         ;; addressing (see bag-opaque-input?), because
         ;; checkInputAddressedPolicy refuses an input-addressed derivation
         ;; that depends on a goonix-addressed item.
         'resolved)
        ((eq? 'opaque (assq-ref (package-properties package) 'self-references))
         'resolved)
        ((memq (%package-addressing-policy) '(content full)) 'content)
        ((eq? (%package-addressing-policy) 'mixed)
         (if ((%upstream-package?) package) 'input 'content))
        ((eq? (%package-addressing-policy) 'adopted)
         ;; Upstream's unmodified packages are lowered input-addressed and
         ;; then adopted (their binary rewritten to a content-addressed item,
         ;; see lower-bag-with-addressing); everything else is built
         ;; content-addressed.  Opaque packages stay resolved (above).
         (if ((%upstream-package?) package) 'input 'content))
        (else 'input)))

(define (adopt-package? package)
  "Whether PACKAGE's own derivation is adopted under the current policy: the
policy is 'adopted', PACKAGE is upstream's, and it is not marked opaque."
  (and (eq? (%package-addressing-policy) 'adopted)
       ((%upstream-package?) package)
       (not (opaque-package? package))))

(define (package-addressing-key)
  "Return the current mode and marker for the package derivation cache."
  (list (%package-addressing-policy) (%upstream-package?)))

(define (bag-opaque-input? bag)
  "Whether BAG directly depends on a package the opaque table (or the opaque
property) marks.  Under 'adopted such a dependency is now RESOLVED-addressed,
and nix/libstore/ca.cc:148 checkInputAddressedPolicy refuses an input-addressed
derivation that depends on a resolved one, so the dependent must be promoted
out of input addressing too."
  (any (match-lambda
         ((label (? package? package) . rest)
          (opaque-package? package))
         (_ #f))
       (append (bag-build-inputs bag)
               (bag-host-inputs bag)
               (bag-target-inputs bag))))

(define (lower-bag-with-addressing lower bag . arguments)
  "Apply the package's own addressing around its bag build, after inputs.
Under the 'adopted policy an upstream package's input-addressed derivation is
adopted (its binary rewritten to a content-addressed item); a flagged item or
glibc is re-lowered content-addressed from source instead."
  (let ((context (and (pair? arguments) (car arguments))))
    (if (package? context)
        ;; goonix: glibc is never adopted (guix/ca/adopt.scm's
        ;; glibc-derivation?), so under 'adopted lower it CONTENT-ADDRESSED
        ;; from the start instead of lowering it input-addressed and adopting
        ;; afterwards.
        ;;
        ;; The IA-then-adopt route cannot work for it: registering the
        ;; input-addressed derivation is itself refused, because
        ;; checkInputAddressedPolicy runs at REGISTRATION
        ;; (nix/libstore/local-store.cc:537, ca.cc:285), not only at build
        ;; time, and glibc's inputs have already been adopted
        ;; (content-addressed).  Measured on CA-6's gate at glibc-2.41 over
        ;; gawk-boot0, and pinned by tests/ca-policy.scm's re-lower group: the
        ;; throw happens inside (package-derivation store glibc-like), before
        ;; any build.
        ;;
        ;; The mark is on glibc's OWN derivation only (%package-addressing).
        ;; The POLICY stays 'adopted for everything lowered inside this
        ;; extent, so the builder's guile, module-import and any package a
        ;; gexp of glibc's build pulls in are still ADOPTED - cheap grafts over
        ;; the input-addressed items the other packages use - rather than
        ;; re-lowered from source.  Measured both ways: with 'content for the
        ;; whole extent, a glibc-named package using (default-guile) got a
        ;; FROM-SOURCE guile-3.0 (graft=0, its own guile-3.0.9.tar input, a
        ;; 198-derivation closure); with the policy left 'adopted the builder
        ;; guile is a graft (graft=1) over the same input-addressed item its
        ;; peers use.  gnu-build-system and trivial-build-system both lower
        ;; the builder's guile inside bag lowering, and glibc passes no
        ;; #:guile, so it is in that case.
        (let* ((glibc? (and (eq? (%package-addressing-policy) 'adopted)
                            (glibc-name? (bag-name bag))))
               ;; goonix: a dependent of an opaque item cannot stay
               ;; input-addressed under 'adopted, because that item is
               ;; resolved and checkInputAddressedPolicy refuses the pairing
               ;; at REGISTRATION.  Promote it to content, the same answer the
               ;; 'mixed policy already gives for an upstream dependent on an
               ;; opaque input.  The rest of the adopted graph keeps its
               ;; addressing; only the affected subgraph changes.
               (opaque-input? (and (eq? (%package-addressing-policy) 'adopted)
                                   (bag-opaque-input? bag))))
          (state-parameterize ((%package-addressing
                                (cond (glibc? 'content)
                                      (opaque-input? 'content)
                                      (else (package-addressing context))))
                               (%package-derivation-name (bag-name bag)))
            (let ((drv (apply lower bag arguments)))
              (if (and (not glibc?) (not opaque-input?)
                       (adopt-package? context))
                  (adopt-lowered-derivation lower bag arguments drv)
                  drv))))
        (apply lower bag arguments))))

(define (adopt-lowered-derivation lower bag arguments drv)
  "Adopt DRV, the monadic input-addressed derivation of an upstream package
under the 'adopted policy.  DRV is built with input-addressed inputs (the
upstream graph); adoption then rewrites its references to adopted items.  If
the scanner flags the item or it is glibc, re-lower it content-addressed from
source instead."
  (with-monad %store-monad
    (>>= (state-parameterize ((%package-addressing-policy 'input))
           drv)
         (lambda (d)
           (lambda (store)
             (let ((adopt ((module-ref (resolve-module '(guix ca adopt))
                                       'adopt-derivation)
                           store d)))
               (if (eq? adopt d)
                   ;; Flagged item: build content-addressed from source.
                   ;;
                   ;; goonix: set the POLICY, not only %package-addressing.
                   ;; This runs inside the outer (state-parameterize
                   ;; ((%package-addressing-policy 'input)) ...) above, and
                   ;; lower-bag-with-addressing OVERWRITES %package-addressing
                   ;; with (package-addressing context), which under the 'input
                   ;; policy returns 'input.  Setting only %package-addressing
                   ;; therefore had no effect on a flagged item's re-lowering.
                   ;; (glibc no longer comes through here at all: it is lowered
                   ;; content-addressed from the start, see
                   ;; lower-bag-with-addressing.)
                   (values (run-with-store store
                             (state-parameterize ((%package-addressing-policy
                                                   'content)
                                                  (%package-addressing 'content))
                               (apply lower bag arguments)))
                           store)
                   (values adopt store))))))))

(define (keyword-argument arguments keyword)
  ;; goonix: walk keyword/value PAIRS.  Stepping one element at a time also
  ;; matches the keyword in a value position (#:local-build? #:addressing),
  ;; which is not an argument named KEYWORD.
  (let loop ((rest arguments))
    (and (pair? rest)
         (pair? (cdr rest))
         (if (eq? (car rest) keyword)
             (cadr rest)
             (loop (cddr rest))))))

(define (addressing-keyword-present? arguments)
  ;; goonix: whether #:addressing was passed as an ARGUMENT, walking
  ;; keyword/value pairs.  A plain memq over the list also finds the keyword
  ;; in a value position (#:local-build? #:addressing), which is not an
  ;; addressing argument at all.
  (let loop ((rest arguments))
    (and (pair? rest)
         (pair? (cdr rest))
         (or (eq? (car rest) #:addressing)
             (loop (cddr rest))))))

(define (strip-keyword arguments keyword)
  "Return ARGUMENTS without KEYWORD and its value."
  ;; goonix: walk keyword/value PAIRS, as keyword-argument does.  Stepping one
  ;; element at a time looked at value positions: with (#:local-build?
  ;; #:addressing #:env-vars (...)) it kept #:local-build?, then saw the decoy
  ;; #:addressing as a keyword and dropped it together with #:env-vars, so the
  ;; lowerer never received the environment variables.  A trailing odd
  ;; element is kept unchanged.
  (let loop ((rest arguments) (result '()))
    (cond ((null? rest) (reverse result))
          ((not (pair? (cdr rest)))
           (loop '() (cons (car rest) result)))
          ((eq? (car rest) keyword)
           (loop (cddr rest) result))
          (else
           (loop (cddr rest) (cons (cadr rest) (cons (car rest) result)))))))

(define (gexp-with-addressing lower name exp . arguments)
  "Apply LOWER with the requested kind for this derivation only.  An explicit
#:addressing #f means 'no override': the keyword is dropped and the kind is
decided as it would be without it, so a caller that passes #f for an
input-addressed derivation (a graft, say) leaves its derivation upstream's."
  (let* ((package-name (%package-derivation-name))
         (explicit (keyword-argument arguments #:addressing))
         (policy (%package-addressing-policy))
         ;; goonix: an explicit #:addressing #f is "no override": a graft over
         ;; an input-addressed derivation passes it (goonix-graft-addressing
         ;; returns #f) so that graft's derivation stays upstream's.  #f is
         ;; falsy, so the `explicit' clause below does not catch it.  Only
         ;; 'adopted honours it: under 'content and 'full everything is
         ;; content-addressed, so there "no override" IS content, and
         ;; guarding those policies too changed their result (measured:
         ;; content and full went from "content" to #f).
         (no-override? (and (eq? policy 'adopted)
                            (addressing-keyword-present? arguments)
                            (not explicit)))
         (requested (cond (explicit explicit)
                          ((and package-name (string=? name package-name))
                           (%package-addressing))
                          ;; goonix: under 'adopted everything that is not an
                          ;; adopted upstream package is content-addressed
                          ;; (plan 01-content-addressing.md, section 8's
                          ;; table).  A gexp is "everything else": leaving it
                          ;; input-addressed made the daemon refuse it once
                          ;; its inputs had been adopted -- "input-addressed
                          ;; derivation depends on content/resolved-addressed
                          ;; ... mark the dependent as content-addressed too"
                          ;; -- which stopped the CA-6 boot gate at
                          ;; module-import-compiled.
                          ((or (memq policy '(content full))
                               (and (eq? policy 'adopted) (not no-override?)))
                           'content)
                          ((eq? policy 'mixed) 'mixed)
                          (else 'input)))
         (arguments (if (memq #:addressing arguments)
                        (strip-keyword arguments #:addressing)
                        arguments)))
    (state-parameterize ((%package-derivation-name #f))
      (apply lower name exp
             (append arguments (list #:addressing requested))))))

(define (input-addressed-derivation? input)
  "Whether a lowered derivation input has no CA addressing marker."
  (not (assoc-ref (derivation-builder-environment-vars
                   (derivation-input-derivation input))
                  "goonixAddressing")))

(define (gexp-inputs-input-addressed? guile inputs graphs)
  (and (every input-addressed-derivation? (cons guile inputs))
       (or (not graphs)
           (every (match-lambda
                    ((_ . inputs)
                     (every input-addressed-derivation?
                            (filter derivation-input?
                                    (if (or (derivation-input? inputs)
                                            (string? inputs))
                                        (list inputs)
                                        inputs)))))
                  graphs))))

(define (references-input-addressed? references)
  (or (not references)
      (every (lambda (path) (not (placeholder-path? path))) references)))

(define (gexp-addressing requested guile inputs graphs allowed disallowed)
  "Choose REQUESTED using the actual lowered inputs and reference paths.

goonix: 'adopted needs this as much as 'mixed.  A gexp can be lowered with a
requested 'input while its inputs have already been adopted (content- or
resolved-addressed); the daemon refuses to REGISTER such a derivation
(checkInputAddressedPolicy runs at registration, not only at build time), so
the kind has to be re-decided from the actual inputs here.

Measured on CA-6's gate with the narrow glibc scope (699dc449953): writing
file-5.46.drv was refused over an adopted gawk-boot0.  A backtrace probe inside
`derivation` named the caller as an ordinary nested package lowering
(package->derivation -> bag->derivation -> expand-input -> package->derivation)
and showed POLICY=adopted MARK=input NAMEPARAM=#f addressing=input at the
leaking lowering.  The wide glibc scope hid the hole because the policy inside
glibc's extent was 'content, so the policy clause in gexp-with-addressing made
those gexps content-addressed anyway.

An explicit #:addressing #f means \"no override\" and arrives here as #f, not
as 'input (gexp-with-addressing keeps it), so a graft over an input-addressed
derivation is untouched by the correction below."
  (if (not (memq (%package-addressing-policy) '(mixed adopted)))
      requested
      (if (and (memq requested '(input mixed))
               (or (not (gexp-inputs-input-addressed? guile inputs graphs))
                   (not (references-input-addressed? allowed))
                   (not (references-input-addressed? disallowed))))
          'content
          (if (eq? requested 'mixed) 'input requested))))

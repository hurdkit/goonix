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

(define (bootstrap-package? package)
  "Whether PACKAGE belongs to the bootstrap/commencement boundary.
Match its module of definition, including bootstrap.scm locations that refer
to bindings implemented in commencement.scm.  No package name list is needed."
  (and=> (package-location package)
         (lambda (location)
           (member (location-file location)
                   '("gnu/packages/commencement.scm"
                     "gnu/packages/bootstrap.scm")))))

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
         ;; Option 2: under 'adopted an opaque item remains input-addressed
         ;; and is not adopted.  Its dependents can retain input addressing.
         ;; Content/full still use the resolved-addressed source path.
         (if (eq? (%package-addressing-policy) 'adopted)
             'input
             'resolved))
        ((and (bootstrap-package? package)
              (eq? (%package-addressing-policy) 'adopted))
         'input)
        ((eq? 'opaque (assq-ref (package-properties package) 'self-references))
         (if (eq? (%package-addressing-policy) 'adopted)
             'input
             'resolved))
        ((memq (%package-addressing-policy) '(content full)) 'content)
        ((eq? (%package-addressing-policy) 'mixed)
         (if ((%upstream-package?) package) 'input 'content))
        ((eq? (%package-addressing-policy) 'adopted)
         ;; Upstream's unmodified packages are lowered input-addressed and
         ;; then adopted (their binary rewritten to a content-addressed item,
         ;; see lower-bag-with-addressing); everything else is built
         ;; content-addressed.  Opaque packages stay input and unadopted.
         (if ((%upstream-package?) package) 'input 'content))
        (else 'input)))

(define (adopt-package? package)
  "Whether PACKAGE's own derivation is adopted under the current policy: the
policy is 'adopted', PACKAGE is upstream's, and it is not marked opaque."
  (and (eq? (%package-addressing-policy) 'adopted)
       ((%upstream-package?) package)
       (not (or (opaque-package? package)
                (bootstrap-package? package)))))

(define (package-addressing-key)
  "Return the current mode and marker for the package derivation cache."
  (list (%package-addressing-policy) (%upstream-package?)))

(define (lower-bag-with-addressing lower bag . arguments)
  "Apply the package's own addressing around its bag build, after inputs.
Under the 'adopted policy an ordinary upstream package's input-addressed
derivation is adopted; an opaque package stays input-addressed and unadopted.
No direct-opaque or glibc-specific dependent promotion is applied."
  (let ((context (and (pair? arguments) (car arguments))))
    (if (package? context)
        (let ((addressing (package-addressing context))
              (opaque-input?
               (and (eq? (%package-addressing-policy) 'adopted)
                    (or (opaque-package? context)
                        (bootstrap-package? context))))
              (adopt? (adopt-package? context)))
          (state-parameterize ((%package-addressing addressing)
                               (%package-derivation-name (bag-name bag)))
            (cond (adopt?
                   (adopt-lowered-derivation lower bag arguments))
                  (opaque-input?
                   ;; Keep the complete upstream derivation, not just its
                   ;; top-level marker: nested gexps and packages must be
                   ;; input-addressed too, so the original output path and
                   ;; its substitutes remain usable.
                   (input-lowering lower bag arguments))
                  (else
                   (apply lower bag arguments)))))
        (apply lower bag arguments))))

(define (input-lowering lower bag arguments)
  "Return the monadic input-addressed lowering of BAG: upstream's derivation,
its nested gexps and package inputs included.

goonix: the monadic value is BUILT inside the 'input extent, not only run
there.  LOWER asks for the derivation of the bag's first input while it
builds its value, and of the others as the lowering runs (mapm over
expand-input in guix/packages.scm); a request for a package computes its
cache key at once, the policy included (package-addressing-key).  A value
built under 'adopted and run under 'input therefore looked a first input
that is a package up under the 'adopted key.  It then took that input's
adoption where a running 'adopted policy had cached one, and the daemon
refused the input-addressed dependent; where none was cached it filed the
input's input-addressed derivation under the 'adopted key, which a package
built from source found later in place of the adoption.  Either way the
result depended on what the connection had lowered before."
  (state-parameterize ((%package-addressing-policy 'input))
    (apply lower bag arguments)))

(define (adopt-lowered-derivation lower bag arguments)
  "Lower BAG, the bag of an upstream package under the 'adopted policy,
input-addressed, with input-addressed inputs (the upstream graph), and adopt
that derivation; adoption then rewrites its references to adopted items.  If
the scanner flags the item, re-lower the item ITSELF content-addressed from
source instead; its inputs keep the 'adopted treatment.  An opaque item is
excluded by adopt-package? and does not enter this path."
  (with-monad %store-monad
    (>>= (input-lowering lower bag arguments)
         (lambda (d)
           (lambda (store)
             (let ((adopt ((module-ref (resolve-module '(guix ca adopt))
                                       'adopt-derivation)
                           store d)))
               (if (eq? adopt d)
                   ;; Flagged item: build it content-addressed from source.
                   ;; (adopt-derivation also returns an item the opaque
                   ;; table names unchanged, but adopt-package? keeps such a
                   ;; package out of this path, so only flagged and
                   ;; glibc-named items arrive here.)
                   ;;
                   ;; goonix: only the item's OWN derivation is content.
                   ;; LOWER is the plain bag lowerer, so the item does not
                   ;; re-enter lower-bag-with-addressing: %package-addressing
                   ;; 'content reaches its bag-named gexp, and its nested
                   ;; gexps are content under 'adopted anyway.  Its package
                   ;; inputs go through the hook under the 'adopted POLICY,
                   ;; so a bootstrap or opaque input stays input-addressed and
                   ;; unadopted and an ordinary input is adopted, as for an
                   ;; unflagged dependent.  The policy is bound explicitly so
                   ;; this holds whatever extent the continuation runs in.
                   ;;
                   ;; A 'content POLICY here re-lowered the whole bag, inputs
                   ;; included, content-addressed from source: package-
                   ;; addressing's bootstrap clause and lower-bag-with-
                   ;; addressing's opaque-input? select input only under
                   ;; 'adopted.  The CA-6 boot probe then built the
                   ;; commencement chain from source, gash-utils-boot first.
                   ;; Table/property opaque items do not enter this path;
                   ;; adopt-package? excludes them before this fallback.
                   (values (run-with-store store
                             (state-parameterize ((%package-addressing-policy
                                                   'adopted)
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

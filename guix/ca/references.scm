;;; goonix: reference-list outputs as required derivation inputs.
;;;
;;; Kept out of upstream's guix/gexp.scm: that file may carry only a short
;;; hook (build-aux/check-goonix-hooks.sh, LIMIT=50 added lines per upstream
;;; file).  The reasoning lives here.
;;;
;;; THE RULE.  An output named in allowedReferences/disallowedReferences is a
;;; REQUIRED INPUT OUTPUT, even when the builder never mentions it.
;;;
;;; WHY.  CA-6 gate run 13 died at glibc-2.41 over gcc-cross-boot0 with
;;;   goonix: unresolved placeholder
;;;   `/gnu/store/eotuouutuotottteeeuuetueetootttt-gcc-cross-boot0-14.3.0-lib'
;;;   in resolved derivation
;;; Measured in the gate's store: glibc takes that derivation as an input but
;;; requests ONLY ["out"], while its allowedReferences names the derivation's
;;; LIB output.  resolveDerivation (nix/libstore/ca.cc) builds its replacement
;;; map from input.second, i.e. the REQUESTED sub-outputs, so lib's placeholder
;;; had no replacement, survived in allowedReferences, and
;;; checkResolvedDerivation refused the derivation at registration.
;;;
;;; WHY HERE, AND NOT IN THE RESOLVER.  Resolution must be a function of the
;;; derivation and its inputs' realisations, NEVER of store contents.  A first
;;; attempt added replacements inside resolveDerivation only for siblings that
;;; happened to be realised already; that was withdrawn, because a substitute
;;; fetching only `out', or a GC of `lib', would make the same derivation
;;; resolve on one machine and be refused on another, and the content address
;;; would depend on store state.  Requesting the output at lowering follows
;;; from the gexp's own reference lists, so it is deterministic, and it forces
;;; no extra build: the input derivation's builder produces all its outputs at
;;; once.
;;;
;;; WHY CA ONLY.  Only a CA derivation carries placeholders that the resolver
;;; must replace.  An input-addressed derivation has real paths in its
;;; reference lists and needs nothing; requesting extra outputs there changes
;;; its .drv and output path and loses upstream substitutes.  Measured: with
;;; the request unconditional, glibc-final's drv moved from upstream's
;;; w189hhbh1r33l2h37qr772rijklxqqxg to 256qrzh1y1y3lmz9jc6wlalgnr50airw, with
;;; gcc-cross-boot0 "out" -> "lib","out" and bash-static "out" -> "doc","out".
;;; glibc-final is under everything, so every input-addressed package would
;;; have been affected.  The caller in gexp.scm therefore passes '() when the
;;; chosen addressing is 'input, and must do so AFTER the addressing binding
;;; that shadows the requested parameter with the kind actually chosen from
;;; the lowered inputs.
;;;
;;; Gates: tests/ca-policy.scm, groups "a reference list may name an output the
;;; dependent does not consume" (CA case) and "an input-addressed derivation's
;;; inputs stay exactly upstream's" (upstream boundary).
(define-module (guix ca references)
  #:use-module (guix derivations)
  #:use-module (guix monads)
  #:use-module (guix store)
  #:use-module (ice-9 match)
  #:export (reference-inputs))

;; <gexp-input> is PRIVATE to (guix gexp), and importing that module here would
;; also be a cycle (gexp.scm reaches this one through module-ref).  So use the
;; exported predicate and accessors, as (guix ca policy) does.  Measured: a
;; match on ($ <gexp-input> …) raised "Unbound variable: <gexp-input>" and broke
;; ca-policy's two reference-promotion tests.
(define (gexp-lower-object)
  ;; Resolved lazily: (guix gexp) reaches this module through module-ref, so a
  ;; #:use-module of it here would be a cycle.
  (@@ (guix gexp) lower-object))

(define (gexp-input? entry)
  ((@@ (guix gexp) gexp-input?) entry))

(define (gexp-input-lowering entry system target)
  (let ((thing ((@@ (guix gexp) gexp-input-thing) entry))
        (output ((@@ (guix gexp) gexp-input-output) entry))
        (native? ((@@ (guix gexp) gexp-input-native?) entry)))
    (mlet %store-monad ((obj ((gexp-lower-object) thing system
                                                #:target (and (not native?) target))))
      (return (and (derivation? obj)
                   (derivation-input obj (list output)))))))

(define (reference-inputs allowed disallowed system target)
  "Return, as a store-monadic value, the <derivation-input>s for every
derivation output named in the reference lists ALLOWED and DISALLOWED.

A package named WITHOUT an output means its \"out\" output: (derivation-input
obj) defaults to ALL outputs, which is how bash-static picked up \"doc\".
Bare output names (\"out\", \"static\") name the dependent's OWN outputs and
are handled by the daemon's checkGoonixReferences; they are not inputs."
  (with-monad %store-monad
    (define (lower entry)
      (cond
       ((string? entry) (return #f))
       ((gexp-input? entry) (gexp-input-lowering entry system target))
       (else
        (mlet %store-monad ((obj ((gexp-lower-object) entry system
                                                      #:target target)))
          (return (and (derivation? obj)
                       (derivation-input obj (list "out"))))))))
    (mlet %store-monad ((inputs (mapm/accumulate-builds
                                 lower (append (or allowed '())
                                               (or disallowed '())))))
      (return (filter derivation-input? inputs)))))
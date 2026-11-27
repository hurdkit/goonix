;;; goonix: parameters around monadic values that a build handler may suspend.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (guix ca parameters)
  #:use-module (guix monads)
  #:export (swapping-parameters
            state-with-parameters/suspendable
            state-keeping-parameters
            state-parameterize/with))

;;; Commentary:
;;;
;;; (guix monads)'s state-with-parameters sets its parameters globally when
;;; its monadic value starts and resets them once the value has returned, and
;;; a gexp's lowering switches grafting the same way (set-grafting).  A build
;;; handler can leave a value in the middle: a build accumulator
;;; (map/accumulate-builds in guix/store.scm) suspends the item that requests
;;; a build, goes on with the other items, and resumes the first one after
;;; the builds.  Plain lowering requests builds in few places.  Under the
;;; adopted policy every adoption requests one, so a value is suspended while
;;; its settings are in force, and the other items of the accumulator were
;;; lowered with them: with grafting off, when the suspended value was a gexp
;;; lowered without grafts, with the addressing and name of a suspended
;;; package, or with the overrides narrowed for a suspended replacement.  The
;;; procedures below set parameters for exactly the time control spends
;;; inside a value.
;;;
;;; They depend on (guix monads) alone, so that (guix package-overrides),
;;; which (guix packages) uses, can have them as well as (guix ca policy).
;;; Which of them a lowering uses is the policy's choice: see
;;; parameter-binder in (guix ca policy).
;;;
;;; Code:

(define (swapping-parameters parameters initial mvalue)
  "Return a value in the state monad that runs MVALUE with PARAMETERS, a list
of parameters, set while control is inside MVALUE and only then.  INITIAL is
a thunk returning the values to start from; it is called when MVALUE is first
entered.  Whenever control leaves MVALUE, because it returned or because a
build handler suspended it, the parameters get back the values they had
outside; when a suspended MVALUE is resumed, they get back the values they
had inside it."
  (lambda (state)
    (let ((inside #f)
          (outside #f))
      (define (current)
        (map (lambda (parameter) (parameter)) parameters))
      (define (install! settings)
        (for-each (lambda (parameter setting) (parameter setting))
                  parameters settings))
      (dynamic-wind
        (lambda ()
          (set! outside (current))
          (install! (or inside (initial))))
        (lambda ()
          (mvalue state))
        (lambda ()
          (set! inside (current))
          (install! outside))))))

(define (state-with-parameters/suspendable parameters values mvalue)
  "Like state-with-parameters, for an MVALUE that a build handler may suspend:
PARAMETERS have VALUES only while control is inside MVALUE."
  (swapping-parameters parameters (const values) mvalue))

(define (state-keeping-parameters parameters mvalue)
  "Run MVALUE; what it does to PARAMETERS is in force only while control is
inside it."
  (swapping-parameters parameters
                       (lambda ()
                         (map (lambda (parameter) (parameter)) parameters))
                       mvalue))

(define-syntax-rule (state-parameterize/with binder ((param value) ...)
                                             body ...)
  ;; state-parameterize of (guix monads), with BINDER in the place of
  ;; state-with-parameters.
  (let ((parameters (list param ...))
        (values (list value ...)))
    (binder parameters values
            (with-fluids* (map parameter-fluid parameters) values
              (lambda ()
                (mbegin %state-monad body ...))))))

;;; parameters.scm ends here

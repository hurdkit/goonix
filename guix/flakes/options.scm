;;; goonix: the command-line options that go with a flake reference.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (guix flakes options)
  #:use-module (guix diagnostics)
  #:use-module (guix i18n)
  #:autoload   (guix flakes resolve) (parse-input-override)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-37)
  #:export (%flake-reference-options
            show-flake-reference-options-help
            flake-options-from-opts
            flake-overrides-from-opts))

;;; Commentary:
;;;
;;; Every command that takes a flake reference takes these two options.
;;; They are apart from the commands so that (guix scripts build), which
;;; the commands share, can have them without loading any of the rest.
;;;
;;; Code:

(define (name=value string)
  "Return two values for STRING, NAME=VALUE: the symbol NAME and VALUE."
  (match (string-index string #\=)
    (#f (leave (G_ "'~a': expected NAME=VALUE~%") string))
    (index (values (string->symbol (string-take string index))
                   (string-drop string (+ index 1))))))

(define %flake-reference-options
  ;; In the form of the standard build options: each passes on what the
  ;; option parser hands it besides the result.
  (list (option '("override-input") #t #f
                (lambda (opt name arg result . rest)
                  (let-values (((name spec) (name=value arg)))
                    (apply values
                           (alist-cons 'flake-override (cons name spec)
                                       result)
                           rest))))
        (option '("option") #t #f
                (lambda (opt name arg result . rest)
                  (let-values (((name value) (name=value arg)))
                    (apply values
                           (alist-cons 'flake-option (cons name value)
                                       result)
                           rest))))))

(define (show-flake-reference-options-help)
  (display (G_ "
      --override-input=NAME=SPEC
                         for a flake reference, take the input NAME from
                         SPEC for this run: a path, or the fields of an
                         input as in flake.scm"))
  (display (G_ "
      --option=NAME=VALUE
                         for a flake reference, give the option NAME of the
                         flake the value VALUE")))

(define (flake-options-from-opts opts)
  "Return the options of a flake that OPTS, the options of a command, give:
an alist of names and texts."
  (reverse (filter-map (match-lambda
                         (('flake-option . pair) pair)
                         (_ #f))
                       opts)))

(define (flake-overrides-from-opts opts)
  "Return the inputs that OPTS, the options of a command, redirect: an alist
of names and <flake-input> records."
  (reverse (filter-map (match-lambda
                         (('flake-override name . spec)
                          (cons name (parse-input-override name spec)))
                         (_ #f))
                       opts)))

;;; options.scm ends here

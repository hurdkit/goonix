;;; goonix: data-only readers for flake manifests and locks.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (guix flakes syntax)
  #:use-module (guix diagnostics)
  #:use-module (guix records)
  #:autoload (guix gexp) (gexp)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-35)
  #:export (flake? flake make-flake flake-input
            flake-format flake-description flake-modules
            flake-inputs flake-options flake-outputs-expression
            flake-source
            flake-input? flake-input-name flake-input-type
            flake-input-url flake-input-path flake-input-branch
            flake-input-tag flake-input-commit flake-input-as
            flake-input-worktree? flake-input-pinned?
            flake-input-follows flake-input-overrides flake-input-options
            flake-input-introduction flake-input-same-as
            flake-option? flake-option-name flake-option-type
            flake-option-default flake-option-description
            read-data-file read-data-string read-data-port read-flake
            sexp->input flake-input->sexp))

(define-record-type* <flake> flake make-flake
  flake?
  (format     flake-format)
  (description flake-description (default ""))
  (modules    flake-modules (default #f))
  (inputs     flake-inputs (default '()))
  (options    flake-options (default '()))
  (outputs-expression flake-outputs-expression (default #f))
  (source     flake-source (default #f)))

(define-record-type* <flake-input> flake-input make-flake-input
  flake-input?
  (name       flake-input-name)
  (type       flake-input-type)
  (url        flake-input-url (default #f))
  (path       flake-input-path (default #f))
  (branch     flake-input-branch (default #f))
  (tag        flake-input-tag (default #f))
  (commit     flake-input-commit (default #f))
  ;; 'flake, 'library or 'source; #f when the declaration does not say, and
  ;; the tree decides.
  (as         flake-input-as (default #f))
  (worktree?  flake-input-worktree? (default #f))
  (pinned?    flake-input-pinned? (default #f))
  (follows    flake-input-follows (default '()))
  (overrides  flake-input-overrides (default '()))
  (options    flake-input-options (default '()))
  (introduction flake-input-introduction (default #f))
  (same-as    flake-input-same-as (default #f)))

(define-record-type* <flake-option> flake-option make-flake-option
  flake-option?
  (name       flake-option-name)
  (type       flake-option-type)
  (default    flake-option-default)
  (description flake-option-description (default "")))

(define (data-error datum message . arguments)
  "Raise a diagnostic for invalid data DATUM.  No datum is ever evaluated."
  (let ((where (source-properties->location (source-properties datum))))
    (raise
     (make-compound-condition
      (condition
       (&message (message (apply format #f message arguments))))
      (condition (&error-location (location where)))))))

(define (call-with-data-reader proc)
  ;; Read data: '#.' is off, and of the reader extensions only those of
  ;; G-expressions are on.  They are in the 'outputs' of most flakes, and
  ;; all they do is to turn #~X into (gexp X) and the like.
  (with-fluids ((read-eval? #f))
    (parameterize ((read-hash-procedures
                    (begin
                      (resolve-interface '(guix gexp)) ;registers them
                      (filter (match-lambda
                                ((char . _) (memv char '(#\~ #\$ #\+))))
                              (read-hash-procedures)))))
      (proc))))

(define* (read-data-port port #:optional (source "data"))
  "Read exactly one S-expression from PORT, without evaluating reader code."
  (let ((result (call-with-data-reader (lambda () (read port)))))
    (when (eof-object? result)
      (data-error (list source) "empty data file"))
    (let ((extra (call-with-data-reader (lambda () (read port)))))
      (unless (eof-object? extra)
        (data-error extra "more than one expression in ~a" source)))
    result))

(define (read-data-file file)
  "Read FILE as one inert S-expression."
  (call-with-input-file file
    (lambda (port)
      (read-data-port port file))))

(define (read-data-string string)
  "Read STRING as one inert S-expression."
  (read-data-port (open-input-string string) "string"))

(define (single properties key default)
  (match (filter (match-lambda (((? (cut eq? key <>)) . _) #t) (_ #f))
                 properties)
    (() default)
    (((_ value)) value)
    ((_ . _) (data-error properties "duplicate '~a' field" key))))

(define (multiple properties key)
  "Return all values of the one list-valued field KEY in PROPERTIES."
  (match (filter (match-lambda (((? (cut eq? key <>)) . _) #t) (_ #f))
                 properties)
    (() '())
    (((_ values ...)) values)
    ((_ . _) (data-error properties "duplicate '~a' field" key))))

(define (flag? properties key)
  (match (filter (match-lambda (((? (cut eq? key <>)) . _) #t) (_ #f))
                 properties)
    (() #f)
    ((_) #t)
    ((_ . _) (data-error properties "duplicate '~a' field" key))))

(define (validate-properties datum allowed)
  (for-each
   (match-lambda
     (((? symbol? key) values ...)
      (unless (memq key allowed)
        (data-error datum "unknown field '~a'" key)))
     (_ (data-error datum "expected a (field value ...) list")))
   datum))

(define (valid-name? name)
  (and (symbol? name)
       (let ((string (symbol->string name)))
         (and (not (string-null? string))
              (string-every (lambda (char)
                              (or (char-alphabetic? char)
                                  (char-numeric? char)
                                  (memv char '(#\- #\_ #\+ #\. #\? #\!))))
                            string)))))

(define (list-of key values)
  ;; A field whose value is a list has (key (item ...)) rather than (key item).
  (if (list? values)
      values
      (data-error values "field '~a' expects a list" key)))

(define (sexp->option datum)
  (match datum
    (((? valid-name? name) type default (? string? description))
     (unless (memq type '(boolean string integer))
       (data-error datum "unsupported option type '~a'" type))
     (unless (case type
               ((boolean) (boolean? default))
               ((string) (string? default))
               ((integer) (integer? default)))
       (data-error datum "default does not match option type '~a'" type))
     (flake-option (name name) (type type) (default default)
                   (description description)))
    (_ (data-error datum
                   "expected (NAME TYPE DEFAULT DESCRIPTION) for an option"))))

(define (sexp->introduction datum)
  (match datum
    ((('commit (? string? commit)) ('signer (? string? signer)))
     datum)
    (_ (data-error datum "expected an introduction with commit and signer"))))

(define (sexp->input datum)
  (unless (and (pair? datum) (valid-name? (car datum)) (list? (cdr datum)))
    (data-error datum "expected (NAME (git URL) ...) for an input"))
  (let ((name (car datum))
        (properties (cdr datum)))
     (validate-properties properties
                          '(git local branch tag commit as worktree pinned
                            inputs options introduction same-as))
     (let* ((git (single properties 'git #f))
            (local (single properties 'local #f))
            (type (cond (git 'git) (local 'local) (else #f)))
            (branch (single properties 'branch #f))
            (tag (single properties 'tag #f))
            (commit (single properties 'commit #f))
            (worktree? (flag? properties 'worktree))
            (pinned? (flag? properties 'pinned))
            (as (single properties 'as #f))
            (same-as (let ((values (multiple properties 'same-as)))
                       (and (pair? values) values)))
            (nested (multiple properties 'inputs))
            (options (multiple properties 'options)))
       (unless (or type same-as)
         (data-error datum "input '~a' needs a source or same-as" name))
       (when same-as
         (match same-as
           (((? string? source) (? valid-name? other))
            (unless (not type) (data-error datum "same-as input has its own source"))
            (set! type 'same-as))
           (_ (data-error datum "same-as expects (PATH-OR-URL NAME)"))))
       (unless (or (eq? type 'same-as)
                   (and (eq? type 'git) (string? git) (not local))
                   (and (eq? type 'local) (string? local) (not git)))
         (data-error datum "invalid URL or local path for input '~a'" name))
       (when (and (eq? type 'local) (or branch tag))
         (data-error datum "a local input cannot have a branch or tag"))
       (when (and (eq? type 'local) worktree? commit)
         (data-error datum "a local worktree input cannot also name a commit"))
       (when (and branch tag)
         (data-error datum "input '~a' has both a branch and a tag" name))
       (unless (memq as '(#f flake library source))
         (data-error datum "invalid input kind '~a'" as))
       (for-each
        (match-lambda
          (((? valid-name? their) 'follows (? valid-name? our))
           #t)
          (((? valid-name? their) spec ...)
           (sexp->input (cons their spec)))
          (_ (data-error datum "invalid nested input replacement")))
        nested)
       (for-each
        (match-lambda
          (((? valid-name? option) value) #t)
          (_ (data-error datum "invalid input option assignment")))
        options)
       (flake-input
        (name name) (type type)
        (url (and (eq? type 'git) git))
        (path (and (eq? type 'local) local))
        (branch branch) (tag tag) (commit commit) (as as)
        (worktree? worktree?) (pinned? pinned?)
        (follows (filter-map (match-lambda
                               ((their 'follows our) (cons their our))
                               (_ #f))
                             nested))
        (overrides (filter-map (match-lambda
                                 ((their 'follows our) #f)
                                 (spec spec))
                               nested))
        (options (map (match-lambda
                        ((option value) (cons option value)))
                      options))
        ;; (introduction (commit COMMIT) (signer FINGERPRINT))
        (introduction (match (multiple properties 'introduction)
                        (() #f)
                        (fields (sexp->introduction fields))))
        (same-as same-as)))))

(define (flake-input->sexp input)
  "Return INPUT as a validated, serializable input declaration."
  `(,(flake-input-name input)
    ,@(case (flake-input-type input)
        ((git) `((git ,(flake-input-url input))))
        ((local) `((local ,(flake-input-path input))))
        ((same-as) '())
        (else (error "invalid input type" (flake-input-type input))))
    ,@(if (flake-input-branch input) `((branch ,(flake-input-branch input))) '())
    ,@(if (flake-input-tag input) `((tag ,(flake-input-tag input))) '())
    ,@(if (flake-input-commit input) `((commit ,(flake-input-commit input))) '())
    ,@(if (flake-input-as input) `((as ,(flake-input-as input))) '())
    ,@(if (flake-input-worktree? input) '((worktree)) '())
    ,@(if (flake-input-pinned? input) '((pinned)) '())
    ,@(if (flake-input-same-as input) `((same-as ,(flake-input-same-as input))) '())
    ,@(if (flake-input-introduction input)
          `((introduction ,@(flake-input-introduction input))) '())
    ,@(if (null? (flake-input-options input)) '()
          `((options ,@(map (match-lambda
                              ((option . value) (list option value)))
                            (flake-input-options input)))))
    ,@(if (and (null? (flake-input-follows input))
               (null? (flake-input-overrides input))) '()
          `((inputs ,@(map (lambda (edge)
                            `(,(car edge) follows ,(cdr edge)))
                          (flake-input-follows input))
                    ,@(flake-input-overrides input))))))

(define (sexp->flake datum source)
  (match datum
    (('flake properties ...)
     (validate-properties properties
                          '(format description modules inputs options outputs))
     (let ((format (single properties 'format #f)))
       (unless (eqv? format 1)
         (data-error datum "unsupported or missing flake format"))
       (flake
        (format format)
        (description (single properties 'description ""))
        (modules (single properties 'modules #f))
        (inputs (map sexp->input (multiple properties 'inputs)))
        (options (map sexp->option (multiple properties 'options)))
        (outputs-expression (single properties 'outputs #f))
        (source source))))
    (_ (data-error datum "expected a (flake (format 1) ...) expression"))))

(define (read-flake file)
  "Read FILE as a flake declaration.  The outputs form remains inert data."
  (sexp->flake (read-data-file file) file))

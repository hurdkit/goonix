;;; goonix: what the 'outputs' procedure of a flake can use.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (guix flakes support)
  #:use-module (guix packages)
  #:use-module ((guix secrets declaration)
                #:select (valid-secret-name? read-secret-declarations))
  #:use-module (guix records)
  #:use-module (guix profiles)
  #:use-module (guix derivations)
  #:use-module (guix gexp)
  #:use-module (guix monads)
  #:use-module (guix store)
  #:use-module (guix search-paths)
  #:use-module ((guix utils) #:select (%current-system))
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  ;; 'system' is also the name of a procedure of Guile; a flake means this
  ;; one.
  #:replace (system)
  #:export (option target
            secret secret-public
            input-source input-output
            self self-file self-revision source-set

            shell shell? shell-packages shell-inputs-from shell-environment
            shell->manifest

            override override? override-original override-replacement

            input-handle? input-handle-derivation input-handle-metadata
            input-handle->manifest-entry

            make-context %ask-host))

;;; Commentary:
;;;
;;; This module runs in the evaluator, which may be a Guix that has never
;;; heard of flakes: the host hands it this file as source.  It therefore
;;; uses only what Guix has had for long.
;;;
;;; Code:

;; What 'outputs' is called with.
(define-record-type <context>
  (make-context system target options source revision inputs)
  context?
  (system   context-system)
  (target   context-target)
  (options  context-options)                      ;alist
  (source   context-source)                       ;the tree, a store item
  (revision context-revision)                     ;commit, or #f
  (inputs   context-inputs))                      ;((NAME AS TREE) ...)

(define %ask-host
  ;; A procedure that takes a request, an S-expression, and returns the
  ;; answer of the host.  The evaluator sets it.
  (make-parameter
   (lambda (request)
     (error "no host to ask" request))))

(define (system context)
  "Return the system that the outputs are for."
  (context-system context))

(define (target context)
  "Return the cross-compilation target, or #f."
  (context-target context))

(define (option context name)
  "Return the value of the option NAME of the flake."
  (match (assq name (context-options context))
    ((_ . value) value)
    (#f (error "the flake declares no such option" name))))

(define (secret-name-string name)
  (unless (valid-secret-name? name)
    (error "secret name must be a safe relative name" name))
  (symbol->string name))

(define (secret-declaration context name)
  (let ((file (self-file context "secrets/vault.scm")))
    (unless (file-exists? file)
      (error "secret reference has no vault declaration" name))
    (or (assq name (call-with-input-file file read-secret-declarations))
        (error "secret is not declared in the vault" name))))

(define (secret context name)
  "Return the runtime path of NAME, never its contents."
  (secret-name-string name)
  (secret-declaration context name)
  (string-append "/run/secrets/" (secret-name-string name)))

(define (secret-public context name)
  "Return the tracked public half of NAME, without opening an identity."
  (secret-name-string name)
  (unless (eq? 'ssh-key (cdr (secret-declaration context name)))
    (error "secret-public is only for an ssh-key secret" name))
  (let ((file (self-file context
                         (string-append "secrets/" (secret-name-string name) ".pub"))))
    (unless (and (file-exists? file)
                 (let ((text (call-with-input-file file get-string-all)))
                   (and (not (string-contains text "PRIVATE KEY"))
                        (not (string-prefix? "AGE-SECRET-KEY-" text)))))
      (error "secret-public: no tracked public half" name))
    file))

(define (input context name)
  (or (assq name (context-inputs context))
      (error "the flake has no such input" name)))

(define (input-source context name)
  "Return the tree of the input NAME: the name of a directory in the store."
  (match (input context name)
    ((_ as tree) tree)))

;; An output of another flake.  Only its derivation and what a consumer
;; needs to know about it cross from that flake's evaluator to this one.
(define-record-type <input-handle>
  (make-input-handle derivation metadata)
  input-handle?
  (derivation input-handle-derivation)            ;file name
  (metadata   input-handle-metadata))             ;alist

(define-gexp-compiler input-handle-compiler <input-handle>
  compiler => (lambda (handle system target)
                (with-monad %store-monad
                  (return (read-derivation-from-file
                           (input-handle-derivation handle)))))
  expander => (lambda (handle derivation output)
                (derivation->output-path derivation output)))

(define (input-output context name kind output)
  "Return a handle to the output OUTPUT of kind KIND of the flake input NAME.
That flake is evaluated in a process of its own, with its own inputs."
  (match (input context name)
    ((_ 'flake tree)
     (match ((%ask-host) `(input-output ,name ,kind ,output))
       (('handle derivation metadata)
        (make-input-handle derivation metadata))
       (answer (error "the host gave no handle" name kind output answer))))
    (_ (error "not a flake input; use (as flake), or 'input-source'" name))))

(define* (input-handle->manifest-entry handle #:optional (output "out"))
  "Return a manifest entry for HANDLE, with the version, the search paths
and the propagated inputs that its flake reported."
  (let ((metadata (input-handle-metadata handle)))
    (manifest-entry
      (name (or (assq-ref metadata 'name) "input"))
      (version (or (assq-ref metadata 'version) "0"))
      (output output)
      (item handle)
      (search-paths (map sexp->search-path-specification
                         (or (assq-ref metadata 'search-paths) '())))
      (dependencies
       (map (match-lambda
              ((name derivation output)
               (manifest-entry
                 (name name) (version "0") (output output)
                 (item (make-input-handle derivation '())))))
            (or (assq-ref metadata 'propagated-inputs) '()))))))

(define (self context)
  "Return the flake itself, for 'self-file', 'source-set' and
'self-revision'."
  context)

(define (self-file context name)
  "Return the name of the file NAME of the flake's own tree."
  (string-append (context-source context) "/" name))

(define (self-revision context)
  "Return the commit of the flake's tree, or #f when the tree has changes
that are not committed."
  (context-revision context))

(define (source-set context . files)
  "Return a store item that holds FILES, files of the flake's own tree named
relative to it, and nothing else: a change to any other file of the tree does
not change it."
  (define source (context-source context))

  (define (components file)
    (let ((parts (string-split file #\/)))
      (when (or (string-null? file) (string-prefix? "/" file)
                (any (lambda (part) (member part '("" "." ".."))) parts))
        (error "source-set: not a file name relative to the tree" file))
      parts))

  (define selected
    ;; Each file, and the directories that lead to it.  All of them must be
    ;; directories of the tree itself: a symbolic link among them would
    ;; lead elsewhere.
    (append-map
     (lambda (file)
       (let loop ((parts (components file)) (directory source) (result '()))
         (match parts
           ((last)
            (let ((name (string-append directory "/" last)))
              (unless (false-if-exception (lstat name))
                (error "source-set: no such file in the tree" file))
              (cons name result)))
           ((head . tail)
            (let ((name (string-append directory "/" head)))
              (unless (eq? 'directory
                           (and=> (false-if-exception (lstat name))
                                  stat:type))
                (error "source-set: reached through something that is not \
a directory of the tree" file))
              (loop tail name (cons name result)))))))
     files))

  (define (below-selected? file)
    ;; A selected directory is taken whole.
    (any (lambda (name)
           (string-prefix? (string-append name "/") file))
         selected))

  (with-store store
    (add-to-store store "source-set" #t "sha256" source
                  #:select? (lambda (file stat)
                              (or (member file selected)
                                  (below-selected? file))))))

;; What 'guix shell' enters.
(define-record-type* <shell> shell make-shell
  shell?
  (packages    shell-packages (default '()))
  (inputs-from shell-inputs-from (default '()))
  (environment shell-environment (default '())))

(define* (shell->manifest object #:optional (system (%current-system)))
  "Return the manifest of OBJECT: a shell, a manifest, or a package, which
stands for the shell that holds this one package."
  (match object
    ((? shell? shell)
     (concatenate-manifests
      (cons (packages->manifest (shell-packages shell))
            (map (lambda (package)
                   (package->development-manifest package system))
                 (shell-inputs-from shell)))))
    ((? manifest? manifest) manifest)
    ((? package? package) (packages->manifest (list package)))
    (_ (error "not a shell, a manifest or a package" object))))

;; One entry of the 'overrides' output: wherever ORIGINAL is lowered,
;; REPLACEMENT is lowered in its place.
(define-record-type <override>
  (override original replacement)
  override?
  (original    override-original)
  (replacement override-replacement))

;;; support.scm ends here

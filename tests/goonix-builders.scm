;;; goonix: the modules that builds import are upstream's.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (test-goonix-builders)
  #:use-module (guix modules)
  #:use-module ((guix build utils) #:select (find-files))
  #:use-module ((guix config) #:select (%git))
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-64))

;;; Commentary:
;;;
;;; A builder imports modules of Guix, and the text of those modules is part
;;; of its derivation.  The modules under guix/build, which the build
;;; systems and the downloads use, and whatever they import in turn,
;;; therefore belong to the derivations of most packages.  If the fork
;;; changes one of those files, or makes one of them import a file of its
;;; own, those derivations are no longer the ones upstream builds, and
;;; every substitute for them is lost.  Nothing else in the test suite
;;; would notice.
;;;
;;; The modules under gnu/build are left out: system builders import
;;; modules of the host side through them, and no two systems share a
;;; derivation anyway.
;;;
;;; Code:

(test-begin "goonix-builders")

(define %source
  ;; The top of the source tree.
  (dirname (dirname (dirname
                     (search-path %load-path "guix/build/utils.scm")))))

(define (git . arguments)
  "Run Git in the source tree and return its exit status."
  (let* ((port (parameterize ((current-error-port (%make-void-port "w")))
                 (apply open-pipe* OPEN_READ %git "-C" %source arguments))))
    (let loop ()
      (unless (eof-object? (read-line port))
        (loop)))
    (status:exit-val (close-pipe port))))

(define %base
  ;; The upstream commit the fork is based on, if this is a checkout that
  ;; has it.
  (let ((file (string-append %source "/build-aux/goonix-upstream-base")))
    (and (file-exists? file)
         (let ((commit (call-with-input-file file read-line)))
           (and (eqv? 0 (git "cat-file" "-e"
                             (string-append commit "^{commit}")))
                commit)))))

(define (modules-below directory)
  "Return the names of the modules whose files are below DIRECTORY, a
directory of the source tree such as \"guix/build\"."
  (map (lambda (file)
         (map string->symbol
              (string-split (string-drop-right
                             (string-drop file
                                          (+ 1 (string-length %source)))
                             (string-length ".scm"))
                            #\/)))
       (find-files (string-append %source "/" directory) "\\.scm$")))

(define (imported-files)
  "Return the files, relative to the source tree, of the modules below
guix/build and of every module of Guix they import."
  (map (lambda (module)
         (string-append (string-join (map symbol->string module) "/")
                        ".scm"))
       (source-module-closure (modules-below "guix/build")
                              #:select? guix-module-name?)))

(define (generated? file)
  "Whether FILE is made by the build and not kept in Git, like
guix/config.scm."
  (not (eqv? 0 (git "ls-files" "--error-unmatch" "--" file))))

(define (upstream? file)
  "Whether FILE is in the upstream commit and has its contents."
  (and (eqv? 0 (git "cat-file" "-e" (string-append %base ":" file)))
       (eqv? 0 (git "diff" "--quiet" %base "--" file))))

(unless %base
  (test-skip 1))
(test-equal "no module that a package build imports differs from upstream"
  '()
  (remove (lambda (file)
            (or (generated? file) (upstream? file)))
          (imported-files)))

(test-end "goonix-builders")

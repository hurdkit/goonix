;;; goonix: an input-addressed graft derivation is byte-identical to upstream's.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (test-ca-graft-identity)
  #:use-module (guix)
  #:use-module (guix tests)
  #:use-module (guix grafts)
  #:use-module (guix gexp)
  #:use-module (guix derivations)
  #:use-module (guix monads)
  #:use-module ((guix config) #:select (%git))
  #:use-module (gnu packages bootstrap)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-64))

;;; Commentary:
;;;
;;; The goonix hooks in guix/grafts.scm substitute three helpers into the
;;; graft build gexp.  For an input-addressed derivation they must leave the
;;; builder text — and hence the derivation — exactly upstream's: the module
;;; list unchanged, the plain 'graft' symbol, and no extra form spliced in.
;;; A stray form ((), #f or (begin)) inserted by the load hook would change
;;; the derivation and lose every upstream substitute, and no other test
;;; notices.  This test reads upstream's guix/grafts.scm from the base
;;; commit, loads it under a different module name, and asserts that
;;; graft-derivation/shallow yields the same derivation file name with both
;;; modules, for one input-addressed derivation and one graft.
;;;
;;; Code:

(test-begin "ca-graft-identity")

(define %source
  (dirname (dirname (dirname
                     (search-path %load-path "guix/build/utils.scm")))))

(define %base
  (let ((file (string-append %source "/build-aux/goonix-upstream-base")))
    (and (file-exists? file)
         (call-with-input-file file read-line))))

(define (git-output . arguments)
  "Run Git in the source tree and return its standard output."
  (let ((port (apply open-pipe* OPEN_READ %git "-C" %source arguments)))
    (let ((str (get-string-all port)))
      (close-pipe port)
      str)))

(define (load-upstream-grafts)
  "Load upstream's guix/grafts.scm from the base commit under the module name
(goonix-test upstream-grafts), and return that module."
  (let* ((text  (git-output "show"
                            (string-append %base ":guix/grafts.scm")))
         (renamed (regexp-substitute/global
                   #f "\\(define-module \\(guix grafts\\)"
                   text 'pre "(define-module (goonix-test upstream-grafts)" 'post))
         (file  (string-append %source "/t-upstream-grafts-"
                               (number->string (getpid)) ".scm")))
    (call-with-output-file file
      (lambda (port) (display renamed port)))
    ;; Load in the default module: the file's own define-module form creates
    ;; (goonix-test upstream-grafts) with the standard bindings and switches
    ;; to it, then restores the current module on return.
    (save-module-excursion
     (lambda ()
       (set-current-module (resolve-module '(guile-user)))
       (load file)))
    (delete-file file)
    (resolve-module '(goonix-test upstream-grafts))))

(define store (open-connection-for-tests))
(%graft? #f)
(%graft-with-utf8-locale? #f)

(define guile-drv (package-derivation store %bootstrap-guile))
(build-derivations store (list guile-drv))

;; One input-addressed derivation and one graft over it.
(define ia-drv
  (run-with-store store
    (gexp->derivation "ia-graft-identity"
      #~(call-with-output-file #$output
          (lambda (p) (display "IA" p)))
      #:addressing 'input
      #:guile-for-build guile-drv)))
(build-derivations store (list ia-drv))

(define ia-repl
  (run-with-store store
    (gexp->derivation "ia-graft-identity"
      #~(call-with-output-file #$output
          (lambda (p) (display "REPL" p)))
      #:addressing 'input
      #:guile-for-build guile-drv)))
(build-derivations store (list ia-repl))

(unless %base
  (test-skip 1))
(test-assert "an input-addressed graft derivation is byte-identical to upstream's"
  (let* ((upstream (load-upstream-grafts))
         (upstream-shallow (module-ref upstream 'graft-derivation/shallow))
         ;; Build the graft record with upstream's own syntactic constructor,
         ;; evaluated in upstream's module so its field macros expand there.
         (upstream-make-graft
          (eval '(lambda (origin replacement)
                   (graft (origin origin) (replacement replacement)))
                upstream))
         ;; The upstream module has its own %graft-with-utf8-locale? parameter
         ;; (default #t); match the test's setting so the only difference the
         ;; test can see is the goonix hooks'.
         (_ ((module-ref upstream '%graft-with-utf8-locale?) #f))
         (grafts  (list (graft (origin ia-drv) (replacement ia-repl))))
         (upstream-grafts
          (list (upstream-make-graft ia-drv ia-repl)))
         (ours     (run-with-store store
                     (graft-derivation/shallow ia-drv grafts
                                               #:guile guile-drv)))
         (theirs   (run-with-store store
                     (upstream-shallow ia-drv upstream-grafts
                                       #:guile guile-drv))))
    (string=? (derivation-file-name ours)
              (derivation-file-name theirs))))

(close-connection store)
(test-end "ca-graft-identity")
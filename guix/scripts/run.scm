;;; goonix: run a flake app.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.

(define-module (guix scripts run)
  #:use-module (guix ui)
  #:use-module (guix store)
  #:use-module (guix derivations)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix diagnostics)
  #:use-module (guix monads)
  #:use-module (guix scripts)
  #:use-module (guix scripts build)
  #:use-module (guix scripts flake)
  #:use-module ((guix utils) #:select (%current-system))
  #:use-module ((guix status) #:select (with-status-verbosity))
  #:use-module (ice-9 match)
  #:use-module (ice-9 ftw)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-37)
  #:export (guix-run))

(define (show-help)
  (display (G_ "Usage: guix run [OPTION...] REF [-- ARG...]
Build and run the app named by the flake reference REF (PATH#NAME).
The app is an 'apps' output of the flake; a 'packages' output is accepted
as a fallback.  ARG... is passed to the program.\n"))
  (show-build-options-help)
  (newline)
  (display (G_ "
  -s, --system=SYSTEM     evaluate for SYSTEM
  -t, --target=TARGET     cross-evaluate for TARGET
  -h, --help              display this help and exit
  -V, --version           display version information and exit"))
  (newline)
  (show-bug-report-information))

(define %options
  (cons* (option '(#\h "help") #f #f
                 (lambda args
                   (leave-on-EPIPE (show-help))
                   (exit 0)))
         (option '(#\V "version") #f #f
                 (lambda args
                   (show-version-and-exit "guix run")))
         (option '(#\s "system") #t #f
                 (lambda (opt name arg result)
                   (alist-cons 'system arg result)))
         (option '(#\t "target") #t #f
                 (lambda (opt name arg result)
                   (alist-cons 'target arg result)))
         %standard-build-options))

(define %default-options
  `((substitutes? . #t)
    (graft? . #t)
    (verbosity . 1)
    (debug . 0)
    (offload? . #t)
    (print-build-trace? . #t)
    (print-extended-build-trace? . #t)
    (multiplexed-build-output? . #t)))

(define (app-executable output name)
  "Return the executable file name for an app built to OUTPUT.  A program-file
app lowers to a single executable file; a package app lowers to a directory
whose bin/ holds the program."
  (cond
   ((and (file-exists? output) (not (file-is-directory? output)))
    output)
   ((file-is-directory? output)
    (let ((bin (string-append output "/bin")))
      (cond
       ((file-exists? (string-append bin "/" (symbol->string name)))
        (string-append bin "/" (symbol->string name)))
       (else
        ;; Fall back to the single executable in bin/, if any.
        (let ((candidates
               (filter-map (lambda (entry)
                             (let ((file (string-append bin "/" entry)))
                               (and (not (member entry '("." "..")))
                                    (file-is-directory? bin)
                                    (false-if-exception
                                     (access? file X_OK))
                                    file)))
                           (or (scandir bin) '()))))
          (match candidates
            ((one) one)
            (() (leave (G_ "app output '~a' has no executable in bin/~%") output))
            (_ (leave (G_ "app output '~a' has several executables; \
name the app explicitly~%") output))))))))
   (else (leave (G_ "app output '~a' does not exist~%") output))))

(define (file-is-directory? file)
  (catch 'system-error
    (lambda () (eq? 'directory (stat:type (stat file))))
    (const #f)))

(define-command (guix-run . args)
  (category development)
  (synopsis "build and run a flake app")
  (with-error-handling
    (let-values (((args command) (break (cut string=? "--" <>) args)))
      (let* ((opts (parse-command-line args %options (list %default-options)
                                       #:build-options? #t))
             (arguments (reverse (filter-map
                                  (match-lambda (('argument . a) a) (_ #f))
                                  opts)))
             (extra-args (match command
                           (() '())
                           (("--" . rest) rest))))
        (match arguments
          ((spec)
           (unless (flake-reference? spec)
             (leave (G_ "'~a' is not a flake reference (expected PATH#NAME)~%")
                    spec))
           (let* ((ref (parse-flake-reference spec))
                  (directory (car ref))
                  (name (or (cdr ref) 'default))
                  (system (or (assoc-ref opts 'system) (%current-system)))
                  (target (assoc-ref opts 'target)))
             (with-status-verbosity (assoc-ref opts 'verbosity)
               (with-store store
                 (set-build-options-from-command-line store opts)
                 (with-build-handler (build-notifier
                                      #:use-substitutes?
                                      (assoc-ref opts 'substitutes?)
                                      #:verbosity (assoc-ref opts 'verbosity))
                   ;; An app of that name, else a package of that name.
                   (let ((drv (flake-output-derivation store directory
                                                       '(apps packages)
                                                       name opts)))
                     (parameterize ((%graft? (assq-ref opts 'graft?)))
                       (build-derivations store (list drv))
                       (let* ((output (derivation->output-path drv))
                              (program (app-executable output name)))
                         (apply execl program program extra-args)))))))))
          (_ (leave (G_ "exactly one flake reference is required~%"))))))))
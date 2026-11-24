;;; goonix: the 'guix flake' command, and flake references for the others.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.

(define-module (guix scripts flake)
  #:use-module (guix flakes)
  #:use-module (guix flakes options)
  #:autoload   (guix flakes evaluate) (evaluate-flake evaluate-flake-outputs
                                       evaluate-flake-shell
                                       evaluate-flake-command)
  #:autoload   (guix pure-eval) (pure-eval-supported?
                                 pure-system-action
                                 build-and-print)
  #:use-module ((guix status) #:select (with-status-verbosity))
  #:use-module (guix store)
  #:use-module (guix derivations)
  #:use-module (guix ui)
  #:use-module (guix scripts)
  #:use-module (guix scripts build)
  #:use-module (guix diagnostics)
  #:use-module (guix i18n)
  #:use-module ((guix utils) #:select (%current-system
                                       arguments-from-environment-variable))
  #:use-module (ice-9 match)
  #:use-module (ice-9 pretty-print)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-34)
  #:use-module (srfi srfi-37)
  #:re-export (%flake-reference-options
               flake-options-from-opts
               flake-overrides-from-opts)
  #:export (guix-flake

            flake-reference?
            parse-flake-reference
            flake-output-derivation
            flake-package-derivation
            flake-command-action
            flake-deploy

            resolve-flake-shell-reference
            flake-default-shell-options))

;;;
;;; Options.
;;;

(define (show-help)
  (display (G_ "Usage: guix flake COMMAND [OPTION]... [ARGUMENT]...
Lock and inspect the flake in the current directory.\n"))
  (newline)
  (display (G_ "The valid values for COMMAND are:\n"))
  (newline)
  (display (G_ "\
   lock             resolve the inputs and write guix.lock; nothing of the
                    flake or of its inputs is evaluated\n"))
  (display (G_ "\
   update [INPUT]...
                    resolve anew all inputs, or those named, and write
                    guix.lock\n"))
  (display (G_ "\
   metadata         print the lock that is in effect: every tree, and why
                    each input points where it does\n"))
  (display (G_ "\
   show             list the outputs\n"))
  (display (G_ "\
   check            evaluate every output and build the checks\n"))
  (display (G_ "\
   init             write a flake.scm to start from\n"))
  (newline)
  (display (G_ "
  -C, --directory=DIR    work on the flake in DIR"))
  (show-flake-reference-options-help)
  (display (G_ "
      --reproducible     with 'check', evaluate twice and compare"))
  (display (G_ "
  -s, --system=SYSTEM    evaluate for SYSTEM"))
  (display (G_ "
      --target=TRIPLET   evaluate for a cross build to TRIPLET"))
  (newline)
  (display (G_ "
  -h, --help             display this help and exit"))
  (display (G_ "
  -V, --version          display version information and exit"))
  (newline)
  (show-bug-report-information))

(define %options
  (append
   %flake-reference-options
   (list (option '(#\h "help") #f #f
                 (lambda args
                   (leave-on-EPIPE (show-help))
                   (exit 0)))
         (option '(#\V "version") #f #f
                 (lambda args
                   (show-version-and-exit "guix flake")))
         (option '(#\C "directory") #t #f
                 (lambda (opt name arg result)
                   (alist-cons 'directory arg result)))
         (option '("reproducible") #f #f
                 (lambda (opt name arg result)
                   (alist-cons 'reproducible? #t result)))
         (option '(#\s "system") #t #f
                 (lambda (opt name arg result)
                   (alist-cons 'system arg result)))
         (option '("target") #t #f
                 (lambda (opt name arg result)
                   (alist-cons 'target arg result))))))


;;;
;;; Flake references: DIRECTORY#NAME.
;;;

(define (flake-reference? spec)
  "Whether SPEC is a flake reference of the form DIRECTORY#NAME."
  (and (string? spec)
       (let ((hash (string-index spec #\#)))
         (and hash (> hash 0) (< hash (- (string-length spec) 1))
              (let ((path (string-take spec hash)))
                (or (string=? path ".") (string=? path "..")
                    (string-prefix? "/" path)
                    (string-prefix? "./" path)
                    (string-prefix? "../" path)))))))

(define (parse-flake-reference spec)
  "Split SPEC into (DIRECTORY . NAME), NAME a symbol.  A reference without a
#NAME part yields NAME #f, which callers resolve to the kind's default."
  (let ((hash (string-index spec #\#)))
    (if hash
        (cons (canonicalize-path (string-take spec hash))
              (string->symbol (string-drop spec (+ hash 1))))
        (cons (canonicalize-path spec) #f))))

(define (flake-output-derivation store directory kind name opts)
  "Return the derivation of the output NAME of kind KIND of the flake in
DIRECTORY, for a command with options OPTS."
  (evaluate-flake store directory kind name
                  #:options (flake-options-from-opts opts)
                  #:overrides (flake-overrides-from-opts opts)
                  #:system (or (assoc-ref opts 'system) (%current-system))
                  #:target (assoc-ref opts 'target)))

(define (flake-package-derivation store spec opts)
  "Return the derivation of the package that SPEC, a flake reference, names,
for 'guix build' with options OPTS."
  (match (parse-flake-reference spec)
    ((directory . name)
     (flake-output-derivation store directory 'packages
                              (or name 'default) opts))))


;;;
;;; 'guix system' and 'guix home'.
;;;

(define (command-arguments reference arguments)
  "Return the arguments that the evaluator gives the command in place of
ARGUMENTS: without REFERENCE, the flake reference, and with the options of
'GUIX_BUILD_OPTIONS', which the user means to apply and which the container
does not have."
  (append (arguments-from-environment-variable "GUIX_BUILD_OPTIONS")
          (delete reference arguments)))

(define (flake-command-action command action args opts arguments)
  "Carry out 'guix COMMAND ARGUMENTS', where COMMAND is 'system or 'home, if
it is one of ours: with '--pure-eval', or on a flake reference.  ACTION, ARGS
and OPTS are what the command made of ARGUMENTS: its action, the arguments
that are not options, and the options.  Return true in that case, and #f if
the command is to go on by itself."
  (define acting?
    ;; The actions that change a machine.
    (memq action '(reconfigure init)))

  (match args
    (_
     (=> next)
     (if (and (eq? command 'system) (assoc-ref opts 'pure-eval?))
         (begin
           (pure-system-action action args opts)
           #t)
         (next)))
    (((? flake-reference? reference) . _)
     (match (parse-flake-reference reference)
       ((directory . name)
        (with-store store
          (set-build-options-from-command-line store opts)
          (let ((names (evaluate-flake-command
                        store directory command
                        (case command
                          ((home) '(homes))
                          (else (if (eq? action 'image)
                                    '(images systems)
                                    '(systems))))
                        (or name 'default)
                        (command-arguments reference arguments)
                        #:options (flake-options-from-opts opts)
                        #:overrides (flake-overrides-from-opts opts)
                        #:system (or (assoc-ref opts 'system)
                                     (%current-system))
                        #:target (assoc-ref opts 'target)
                        #:act? acting?)))
            ;; What acts has acted; what only builds is built here.
            (unless acting?
              (build-and-print store names opts))
            #t)))))
    (_ #f)))

(define (flake-deploy file opts arguments)
  "If FILE, the file given to 'guix deploy ARGUMENTS', is a flake reference,
deploy the machines it names and exit; return #f otherwise."
  (and (flake-reference? file)
       (match (parse-flake-reference file)
         ((directory . name)
          (with-store store
            (set-build-options-from-command-line store opts)
            (evaluate-flake-command
             store directory 'deploy '(machines) (or name 'default)
             (command-arguments file arguments)
             #:options (flake-options-from-opts opts)
             #:overrides (flake-overrides-from-opts opts)
             #:system (or (assoc-ref opts 'system) (%current-system))
             #:act? #t))
          (exit 0)))))


;;;
;;; 'guix shell'.
;;;

(define (flake-shell-reference? spec)
  "Whether SPEC, an argument of 'guix shell', names a flake: DIRECTORY#NAME,
or a directory given as a path that holds a flake.scm."
  (and (string? spec)
       (or (flake-reference? spec)
           (and (not (string-index spec #\#))
                (or (member spec '("." ".."))
                    (string-prefix? "./" spec)
                    (string-prefix? "../" spec)
                    (string-prefix? "/" spec))
                (file-exists? (string-append spec "/flake.scm"))))))

(define (flake-shell-options directory name opts development? optional?)
  "Evaluate in a container what 'guix shell' enters for NAME in the flake of
DIRECTORY, build its profile, and return the options that stand for it: the
profile and the environment variables the shell sets.  Return #f when
OPTIONAL? and the flake has nothing of that name.  The flake's code never
runs in this process."
  (unless (pure-eval-supported?)
    (leave (G_ "a flake shell is evaluated in a container, which needs \
unprivileged user namespaces~%")))
  (with-status-verbosity (or (assoc-ref opts 'verbosity) 1)
    (with-store store
      (set-build-options-from-command-line store opts)
      (let-values (((drv environment)
                    (evaluate-flake-shell
                     store directory name
                     #:development? development?
                     #:optional? optional?
                     #:bootstrap? (assoc-ref opts 'bootstrap?)
                     #:options (flake-options-from-opts opts)
                     #:overrides (flake-overrides-from-opts opts)
                     #:system (or (assoc-ref opts 'system)
                                  (%current-system)))))
        (and drv
             (let ((dry-run? (assoc-ref opts 'dry-run?)))
               (with-build-handler
                   (build-notifier #:use-substitutes?
                                   (assoc-ref opts 'substitutes?)
                                   #:verbosity (assoc-ref opts 'verbosity)
                                   #:dry-run? dry-run?)
                 (build-derivations store (list drv)))
               (when dry-run?
                 (exit 0))
               (cons (cons 'profile (derivation->output-path drv))
                     (map (match-lambda
                            ((variable . value)
                             (cons 'environment-variables
                                   (cons variable value))))
                          environment))))))))

(define (resolve-flake-shell-reference opts)
  "If the packages named in OPTS, the options of 'guix shell', include a
flake reference, return OPTS with that reference replaced by the profile of
the shell it names.  With '-D' the reference names a package and stands for
its development environment.  Return OPTS unchanged otherwise."
  (define (payload? option)
    (match option
      (((or 'package 'load 'manifest 'profile 'expression) . _) #t)
      (_ #f)))

  (define (reference? option)
    (match option
      (('package _ (? flake-shell-reference?)) #t)
      (_ #f)))

  (match (filter reference? opts)
    (() opts)
    ((('package mode spec))
     (unless (= 1 (count payload? opts))
       (leave (G_ "'~a': a flake shell cannot be combined with other \
packages, files or profiles~%")
              spec))
     (match (parse-flake-reference spec)
       ((directory . name)
        (append (flake-shell-options directory (or name 'default) opts
                                     (eq? mode 'package) #f)
                (remove reference? opts)))))
    ((_ (_ _ spec) . _)
     (leave (G_ "'~a': only one flake shell can be entered~%") spec))))

(define (flake-default-shell-options file opts)
  "Return OPTS, the options of 'guix shell', extended with the default shell
of the flake that FILE, a flake.scm, defines.  This is what 'guix shell'
without arguments enters."
  (let ((directory (dirname (canonicalize-path file))))
    (append (or (flake-shell-options directory 'default opts #f #t)
                (leave (G_ "'~a' has no shell named 'default'~%") file))
            opts)))

;;;
;;; The command.
;;;

(define %starter-flake
  "(flake
 (format 1)
 (description \"\")

 ;; What this flake is made from.  'guix flake lock' pins each of them;
 ;; nothing here is evaluated.
 (inputs)

 ;; The one part that is code.  It runs in a container and returns an alist
 ;; of kinds of outputs, each an alist of names and values.
 (outputs
  (lambda (in)
    (use-modules (gnu packages base))
    `((packages (default . ,hello))))))
")

(define (flake-directory opts)
  "Return the directory of the flake that OPTS, the options of 'guix flake',
are about; it must hold a flake.scm."
  (let ((directory (canonicalize-path (or (assoc-ref opts 'directory) "."))))
    (unless (file-exists? (string-append directory "/flake.scm"))
      (leave (G_ "'~a' has no flake.scm~%") directory))
    directory))

(define (arguments opts)
  (reverse (filter-map (match-lambda
                         (('argument . argument) argument)
                         (_ #f))
                       opts)))

(define (no-arguments command opts)
  (unless (null? (arguments opts))
    (leave (G_ "'guix flake ~a' takes no argument; see '--directory'~%")
           command)))

(define (flake-outputs store opts)
  "Return the outputs of the flake of OPTS, evaluated anew."
  (evaluate-flake-outputs store (flake-directory opts)
                          #:options (flake-options-from-opts opts)
                          #:overrides (flake-overrides-from-opts opts)
                          #:system (or (assoc-ref opts 'system)
                                       (%current-system))
                          #:target (assoc-ref opts 'target)
                          #:cache? (not (assoc-ref opts 'reproducible?))))

(define (flake-lock-command opts update)
  (let ((directory (flake-directory opts)))
    (unless (null? (flake-overrides-from-opts opts))
      (leave (G_ "an override is for one run and never goes into guix.lock; \
give it to the command that is to use it, or put it in flake.local.scm~%")))
    (lock-flake directory #:update update)
    ;; What flake.local.scm redirects is resolved again as well.
    (unless (and (null? (read-local-overrides directory))
                 (equal? update '()))
      (unless (null? (read-local-overrides directory))
        (effective-flake-lock directory #:update? #t)))
    (format #t "~a~%" (string-append directory "/guix.lock"))))

(define (flake-check store opts)
  "Evaluate every output of the flake of OPTS and build its checks.  With
'--reproducible', evaluate twice and compare."
  (let ((outputs (flake-outputs store opts)))
    (when (assoc-ref opts 'reproducible?)
      (let ((again (flake-outputs store opts)))
        (for-each (lambda (first second)
                    (unless (equal? first second)
                      (match first
                        ((kind name _)
                         (report-error (G_ "~a ~a is not the same in two \
evaluations~%")
                                       kind name)))))
                  outputs again)
        (unless (equal? outputs again)
          (exit 1))))
    (match (filter-map (match-lambda
                         (('checks name derivation) derivation)
                         (_ #f))
                       outputs)
      (()
       (info (G_ "every output was evaluated; the flake has no checks~%")))
      (checks
       (build-derivations store (map read-derivation-from-file checks))))))

(define-command (guix-flake . args)
  (category development)
  (synopsis "lock and inspect flakes")

  (with-error-handling
    (match args
      (()
       (leave (G_ "missing command; try 'guix flake --help'~%")))
      (((or "-h" "--help") . _)
       (leave-on-EPIPE (show-help)))
      (((or "-V" "--version") . _)
       (show-version-and-exit "guix flake"))
      ((command . rest)
       (let ((opts (parse-command-line rest %options (list '())
                                       #:build-options? #f)))
         (match command
           ("lock"
            (no-arguments command opts)
            (flake-lock-command opts '()))
           ("update"
            (flake-lock-command opts
                                (match (arguments opts)
                                  (() #t)
                                  (names (map string->symbol names)))))
           ("metadata"
            (no-arguments command opts)
            (pretty-print
             (flake-metadata
              (effective-flake-lock (flake-directory opts)
                                    #:overrides
                                    (flake-overrides-from-opts opts)))))
           ("show"
            (no-arguments command opts)
            (with-store store
              (for-each (match-lambda
                          ((kind name derivation)
                           (format #t "~a ~a ~a~%" kind name
                                   (or derivation "-"))))
                        (flake-outputs store opts))))
           ("check"
            (no-arguments command opts)
            (with-status-verbosity 1
              (with-store store
                (flake-check store opts))))
           ("init"
            (no-arguments command opts)
            (let ((file (string-append (or (assoc-ref opts 'directory) ".")
                                       "/flake.scm")))
              (when (file-exists? file)
                (leave (G_ "'~a' exists~%") file))
              (call-with-output-file file
                (lambda (port)
                  (display %starter-flake port)))
              (format #t "~a~%" file)))
           (_
            (leave (G_ "~a: unknown command; try 'guix flake --help'~%")
                   command))))))))

;;; flake.scm ends here

;;; goonix: the process that runs the 'outputs' procedure of a flake.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (guix flakes evaluator)
  #:use-module (guix flakes support)
  #:use-module (guix store)
  #:use-module (guix packages)
  #:use-module (guix search-paths)
  #:use-module (guix derivations)
  #:use-module (guix gexp)
  #:use-module (guix monads)
  #:use-module ((guix profiles)
                #:select (profile-derivation %default-profile-hooks))
  #:use-module ((guix utils) #:select (%current-system
                                       %current-target-system))
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (run-flake-evaluator
            command-object
            record-object?))

;;; Commentary:
;;;
;;; The host starts this in a container, under the Guix that the flake
;;; pins, and hands it this file and (guix flakes support) as source: that
;;; Guix need not know about flakes.  The host writes one request on file
;;; descriptor 3 and reads the answers on file descriptor 4:
;;;
;;;   (guix VERSION)                  what Guix this is: a commit, if it
;;;                                   was built from one
;;;   (output KIND NAME DRV METADATA) an output, lowered
;;;   (entry KIND NAME)               an output that is not lowered
;;;   (absent KIND NAME)              an optional output that is not there
;;;   (input-output NAME KIND OUTPUT) a question; the host answers on 3
;;;   (derivations DRV ...)           what a command would build; when the
;;;                                   command is to act, the host answers
;;;                                   (proceed) or (refuse) on 3
;;;   (done)
;;;
;;; An error is reported on standard error and ends the process with a
;;; failure.
;;;
;;; Code:

(define %lowered-kinds
  ;; The kinds whose values become derivations.  The others ('overrides',
  ;; 'templates', 'machines', and whatever a flake invents) are only listed.
  '(packages shells systems homes images checks apps))

(define (override-parameter)
  "Return the parameter that holds the overrides during lowering, or #f in a
Guix that has none."
  (and=> (false-if-exception (resolve-interface '(guix package-overrides)))
         (lambda (interface)
           (module-ref interface '%package-overrides))))

(define (call-with-overrides overrides thunk)
  "Call THUNK with OVERRIDES, a list of <override> records, in effect for
every package that is lowered."
  (match (override-parameter)
    (#f
     (unless (null? overrides)
       (error "this flake has overrides, which need goonix as its 'guix' \
input"))
     (thunk))
    (parameter
     (parameterize ((parameter
                     (map (lambda (override)
                            (cons (override-original override)
                                  (override-replacement override)))
                          overrides)))
       (thunk)))))

(define (optional-binding module variable)
  "Return the procedure VARIABLE of MODULE, loading MODULE if it is defined.
Record predicates are macros: evaluate their name in the defining module."
  (let ((interface (resolve-module module #:ensure #f)))
    (and (module-defined? interface variable)
         (let ((value (module-ref (resolve-module module) variable)))
           (if (macro? value)
               (eval variable (resolve-module module))
               value)))))

(define (record-object? object module predicate)
  "Whether OBJECT satisfies PREDICATE, a record predicate exported by MODULE.
Resolve the predicate in its own module, where its macro expands to a procedure."
  (and (resolve-module module #f #:ensure #f)
       (and=> (optional-binding module predicate)
              (lambda (procedure) (procedure object)))))

(define (lower store object name system target)
  "Return the derivation of OBJECT, the output NAME of a flake."
  (define (is? module predicate)
    (record-object? object module predicate))

  (run-with-store store
    (cond ((derivation? object)
           (with-monad %store-monad (return object)))
          ((shell? object)
           (profile-derivation (shell->manifest object system)
                               #:system system))
          ((is? '(gnu system) 'operating-system?)
           ((module-ref (resolve-module '(gnu system))
                        'operating-system-derivation)
            object))
          ((is? '(gnu image) 'image?)
           (lower-object ((module-ref (resolve-module '(gnu system image))
                                      'system-image)
                          object)))
          ((is? '(gnu home) 'home-environment?)
           ((module-ref (resolve-module '(gnu home))
                        'home-environment-derivation)
            object))
          ((gexp? object)
           (gexp->derivation name object #:system system #:target target))
          ((or (package? object) (file-like? object)
               (input-handle? object))
           (lower-object object system #:target target))
          (else
           (error "this output is not something that can be built"
                  name object)))
    #:system system #:target target))

(define (metadata store object system target)
  "Return what a consumer of OBJECT in another process needs to know."
  (cond ((package? object)
         `((name . ,(package-name object))
           (version . ,(package-version object))
           (outputs . ,(package-outputs object))
           (search-paths . ,(map search-path-specification->sexp
                                 (package-native-search-paths object)))
           (propagated-inputs
            . ,(filter-map
                (match-lambda
                  ((label (? package? input) . rest)
                   (list (package-name input)
                         (derivation-file-name
                          (lower store input label system target))
                         (match rest
                           ((output) output)
                           (() "out"))))
                  (_ #f))
                (package-propagated-inputs object)))))
        ((shell? object)
         `((environment . ,(shell-environment object))))
        ((derivation? object)
         `((outputs . ,(map car (derivation-outputs object)))))
        (else '())))

(define (requested-shell outputs name development?)
  "Return what 'guix shell' enters for NAME among OUTPUTS, or #f: the shell
of that name, else the package of that name; with DEVELOPMENT?, the
development environment of the package of that name."
  (let ((shells   (or (assq-ref outputs 'shells) '()))
        (packages (or (assq-ref outputs 'packages) '())))
    (if development?
        (and=> (assq-ref packages name)
               (lambda (package)
                 (shell (inputs-from (list package)))))
        (or (assq-ref shells name) (assq-ref packages name)))))

(define (shell-profile store object system bootstrap?)
  "Return the derivation of the profile of OBJECT, made the way 'guix shell'
makes the profile of a manifest.  BOOTSTRAP? is its '--bootstrap'."
  (run-with-store store
    (profile-derivation (shell->manifest object system)
                        #:system system
                        #:allow-collisions? #t
                        #:hooks (if bootstrap? '() %default-profile-hooks)
                        #:locales? (not bootstrap?))
    #:guile-for-build
    (package-derivation store
                        (if bootstrap?
                            (module-ref (resolve-interface
                                         '(gnu packages bootstrap))
                                        '%bootstrap-guile)
                            (default-guile))
                        system)
    #:system system))

(define (guix-version)
  "Return what the Guix that runs this calls itself: the commit it was built
from when it was built from a channel, as 'guix pull' and 'guix time-machine'
build it."
  (module-ref (resolve-module '(guix config)) '%guix-version))

(define command-object
  ;; The value of the output that the command under way is about.  The
  ;; command gets it through its '--expression' option; see 'run-command'.
  (make-parameter #f))

(define %expression
  ;; What a command is told to evaluate to get the object.
  "((@ (guix flakes evaluator) command-object))")

(define (run-command command arguments act?)
  "Run 'guix COMMAND ARGUMENTS' on the value of 'command-object': COMMAND is
'system, 'home or 'deploy, and ARGUMENTS the arguments it was given without
the flake reference.  Without ACT?, stop at the derivations and return their
file names."
  (define main
    ;; The entry point of the command, which every Guix exports.
    (match command
      ('system (module-ref (resolve-interface '(guix scripts system))
                           'guix-system))
      ('home (module-ref (resolve-interface '(guix scripts home))
                         'guix-home))
      ('deploy (module-ref (resolve-interface '(guix scripts deploy))
                           'guix-deploy))
      (_ (error "no such command for a flake" command))))

  (define (printed-derivations thunk)
    ;; With '--derivation' a command prints derivation file names; anything
    ;; else on standard output is the flake's doing.
    (let ((lines (string-split (with-output-to-string thunk) #\newline)))
      (for-each (lambda (line)
                  (unless (or (string-null? line) (derivation-path? line))
                    (display line (current-error-port))
                    (newline (current-error-port))))
                lines)
      (filter derivation-path? lines)))

  (define (machine-systems)
    ;; 'guix deploy' has no '--derivation': what it would deploy is the
    ;; system of each machine.
    (let ((machines (match (command-object)
                      ((? list? machines) machines)
                      (machine (list machine))))
          (system-of (module-ref (resolve-interface '(gnu machine))
                                 'machine-operating-system))
          (derivation-of (module-ref (resolve-interface '(gnu system))
                                     'operating-system-derivation)))
      (with-store store
        ;; The one build option that changes a derivation.
        (parameterize ((%graft? (not (member "--no-grafts" arguments))))
          (map (lambda (machine)
                 (derivation-file-name
                  (run-with-store store
                    (derivation-of (system-of machine)))))
               machines)))))

  (define (run . more)
    (apply main (append arguments (list "-e" %expression) more)))

  (cond (act? (run))
        ((eq? command 'deploy) (machine-systems))
        (else (printed-derivations (lambda () (run "-d"))))))

(define (flake-outputs request)
  "Call the 'outputs' procedure of the flake of REQUEST and return its
value: an alist of kinds and alists of names and values."
  (define source (assq-ref request 'source))

  (define form
    (match (call-with-input-file (string-append source "/flake.scm") read)
      (('flake . fields)
       (match (assq 'outputs fields)
         ((_ form) form)
         (_ (error "the flake has no 'outputs'"))))))

  (define module
    (let ((module (make-fresh-user-module)))
      (module-use! module (resolve-interface '(guix flakes support)))
      module))

  ;; The flake's own modules, and those of its library inputs.
  (set! %load-path
        (append (match (assq-ref request 'modules)
                  (#f '())
                  (directory (list (string-append source "/" directory))))
                (filter-map (match-lambda
                              ((name 'library tree directory) directory)
                              (_ #f))
                            (assq-ref request 'inputs))
                %load-path))

  ;; The body of 'outputs' may begin with (use-modules ...): that is how a
  ;; flake names the modules it uses.
  (match form
    (('lambda formals . body)
     (for-each (lambda (form)
                 (match form
                   (('use-modules . _) (eval form module))
                   (_ #f)))
               body))
    (_ #f))

  (let ((outputs ((eval form module)
                  (make-context (assq-ref request 'system)
                                (assq-ref request 'target)
                                (assq-ref request 'options)
                                source
                                (assq-ref request 'revision)
                                (map (match-lambda
                                       ((name as tree . _)
                                        (list name as tree)))
                                     (assq-ref request 'inputs))))))
    (unless (and (list? outputs)
                 (every (match-lambda
                          (((? symbol?) . (? list? entries))
                           (every (match-lambda
                                    (((? symbol?) . _) #t)
                                    (_ #f))
                                  entries))
                          (_ #f))
                        outputs))
      (error "'outputs' must return an alist of kinds, each an alist of \
names and values"))
    outputs))

(define (answer-request request send receive)
  "Evaluate REQUEST and call SEND with each answer; RECEIVE returns what the
host says next."
  (let* ((system    (assq-ref request 'system))
         (target    (assq-ref request 'target))
         (outputs   (flake-outputs request))
         (overrides (map cdr (or (assq-ref outputs 'overrides) '()))))
    (unless (every override? overrides)
      (error "'overrides' must hold (override ORIGINAL REPLACEMENT) values"))
    (with-store store
      (parameterize ((%current-system system)
                     (%current-target-system target))
        (call-with-overrides overrides
          (lambda ()
            (define (send-output kind name object)
              (send `(output ,kind ,name
                             ,(derivation-file-name
                               (lower store object (symbol->string name)
                                      system target))
                             ,(metadata store object system target))))

            (define (kind-of kinds name)
              ;; The first of KINDS that has an output called NAME.
              (or (find (lambda (kind)
                          (assq name (or (assq-ref outputs kind) '())))
                        kinds)
                  (error "the flake has no such output" kinds name)))

            (define (output-of kinds name)
              (assq-ref (assq-ref outputs (kind-of kinds name)) name))

            (match (assq-ref request 'want)
              (('output (? symbol? kind) name)
               (send-output kind name (output-of (list kind) name)))
              (('output (? list? kinds) name)
               (send-output (kind-of kinds name) name
                            (output-of kinds name)))
              (('all)
               (for-each
                (match-lambda
                  ((kind . entries)
                   (for-each (match-lambda
                               ((name . object)
                                (if (memq kind %lowered-kinds)
                                    (send-output kind name object)
                                    (send `(entry ,kind ,name)))))
                             entries)))
                outputs))
              (('command command kinds name arguments act?)
               (parameterize ((command-object (output-of kinds name)))
                 (send `(derivations
                         ,@(run-command command arguments #f)))
                 (when act?
                   (match (receive)
                     (('proceed) (run-command command arguments #t))
                     (_ #f)))))
              (('shell name options)
               (match (requested-shell outputs name
                                       (assq-ref options 'development?))
                 (#f
                  (if (assq-ref options 'optional?)
                      (send `(absent shells ,name))
                      (error "the flake has neither a shell nor a package \
of this name" name)))
                 (object
                  (send `(output shells ,name
                                 ,(derivation-file-name
                                   (shell-profile store object system
                                                  (assq-ref options
                                                            'bootstrap?)))
                                 ((environment
                                   . ,(if (shell? object)
                                          (shell-environment object)
                                          '())))))))))))))))

(define (run-flake-evaluator)
  "Read a request from file descriptor 3 and answer on file descriptor 4."
  (let* ((from-host (fdopen 3 "r"))
         (to-host   (fdopen 4 "w"))
         (send      (lambda (datum)
                      (write datum to-host)
                      (newline to-host)
                      (force-output to-host))))
    ((module-ref (resolve-interface '(guix ui)) 'call-with-error-handling)
     (lambda ()
       (send `(guix ,(guix-version)))
       (parameterize ((%ask-host (lambda (question)
                                   (send question)
                                   (read from-host))))
         (answer-request (read from-host) send
                         (lambda () (read from-host))))
       (send '(done))))))

;;; evaluator.scm ends here

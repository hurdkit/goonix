;;; goonix: evaluating the outputs of a flake, from the host's side.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (guix flakes evaluate)
  #:use-module (guix flakes syntax)
  #:use-module (guix flakes lock)
  #:use-module (guix flakes resolve)
  #:use-module (guix flakes checkout)
  #:use-module (guix pure-eval)
  #:use-module (guix store)
  #:use-module (guix derivations)
  #:use-module (guix diagnostics)
  #:use-module (guix i18n)
  #:use-module (guix records)
  #:use-module (guix base16)
  #:use-module ((guix build utils) #:select (mkdir-p find-files))
  #:use-module ((guix config) #:select (%guile))
  #:use-module ((guix channels) #:select (channel))
  #:use-module ((guix utils) #:select (%current-system cache-directory
                                       with-atomic-file-output))
  #:autoload   (guix scripts build) (register-root)
  #:use-module (gcrypt hash)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-34)
  #:export (evaluate-flake
            evaluate-flake-outputs
            evaluate-flake-shell
            evaluate-flake-command

            %locked-guix-directory
            evaluator-sources
            evaluator-starts
            %evaluations))

;;; Commentary:
;;;
;;; An evaluation concerns one instance: a flake's tree, the edges of the
;;; lock that are its inputs, and the options it is given.  The flake a
;;; command names is one instance; each flake input it asks an output of is
;;; another, evaluated in a process of its own with its own edges, which are
;;; in the same lock.
;;;
;;; The host imports the trees, starts the evaluator in a container (see
;;; (guix pure-eval)), sends the request and answers the evaluator's
;;; questions.  Only derivation file names and plain data come back.
;;;
;;; Code:

(define-record-type* <instance> instance make-instance
  instance?
  (id       instance-id)                  ;"" for the flake, else a node ID
  (tree     instance-tree)                ;its files, a store item
  (edges    instance-edges)               ;its inputs, <lock-edge> records
  (options  instance-options (default '())) ;alist of names and values
  (revision instance-revision (default #f))) ;commit of a clean tree

;; What one command works with.
(define-record-type* <session> session make-session
  session?
  (store     session-store)
  (directory session-directory)           ;of the flake the command names
  (lock      session-lock)
  (system    session-system)
  (target    session-target)
  (trees     session-trees)               ;hash table: node ID -> store item
  ;; Hash table: instance ID -> what 'instance-evaluator' returns.
  (evaluators session-evaluators)
  ;; Whether to take evaluations from the cache; they go into it anyway.
  (cache?    session-cache? (default #t)))

(define evaluator-starts
  ;; The number of evaluator processes started, for the tests: a cache hit
  ;; starts none.
  (make-parameter 0))

(define (node-tree session node)
  "Return the store item of the files of NODE, imported once per SESSION and
checked against the hash of the lock."
  (or (hash-ref (session-trees session) (lock-node-id node))
      (let ((item (import-tree (session-store session)
                               (lock-node-tree node
                                               (session-directory session))
                               (lock-node-id node))))
        (hash-set! (session-trees session) (lock-node-id node) item)
        item)))

(define (edge-node session edge)
  (flake-lock-node (session-lock session) (lock-edge-node edge)))

(define (library-directory tree)
  "Return the directory of TREE that holds its Scheme modules: the one its
flake.scm or its .guix-channel names, else TREE."
  (define (field name head key)
    ;; The value of the field KEY of the form that the file NAME of TREE
    ;; holds, if that form begins with HEAD.
    (match (and=> (regular-file tree name) read-data-file)
      (((? symbol? symbol) . fields)
       (and (eq? symbol head)
            (match (assq key fields)
              ((_ (? string? directory)) directory)
              (_ #f))))
      (_ #f)))

  (match (or (field "flake.scm" 'flake 'modules)
             (field ".guix-channel" 'channel 'directory))
    (#f tree)
    (directory (string-append tree "/" directory))))

(define (typed-options flake given)
  "Return the options of FLAKE as an alist of names and values: for each
declared option the value GIVEN has for it, checked against its type and
converted if it is text from the command line, else its default.  An option
that FLAKE does not declare is an error."
  (define (value option given)
    (define (mismatch)
      (raise (formatted-message
              (G_ "option '~a' takes a ~a, not ~s")
              (flake-option-name option) (flake-option-type option) given)))

    (case (flake-option-type option)
      ((boolean)
       (cond ((boolean? given) given)
             ((equal? given "true") #t)
             ((equal? given "false") #f)
             (else (mismatch))))
      ((integer)
       (cond ((and (integer? given) (exact? given)) given)
             ((and (string? given) (string->number given))
              => (lambda (number)
                   (if (and (integer? number) (exact? number))
                       number
                       (mismatch))))
             (else (mismatch))))
      ((string)
       (if (string? given) given (mismatch)))))

  (for-each (match-lambda
              ((name . _)
               (unless (find (lambda (option)
                               (eq? name (flake-option-name option)))
                             (flake-options flake))
                 (raise (formatted-message
                         (G_ "the flake declares no option '~a'") name)))))
            given)
  (map (lambda (option)
         (cons (flake-option-name option)
               (match (assq (flake-option-name option) given)
                 (#f (flake-option-default option))
                 ((_ . given) (value option given)))))
       (flake-options flake)))


;;;
;;; The evaluator process.
;;;

(define (evaluator-sources store)
  "Return a store directory that holds the source of the modules the
evaluator runs, to be put first on its load path: the Guix that evaluates a
flake need not have them."
  (define (source module)
    (or (search-path %load-path module)
        (raise (formatted-message (G_ "cannot find ~a") module))))

  (add-file-tree-to-store
   store
   `("flake-evaluator" directory
     ("guix" directory
      ("flakes" directory
       ("evaluator.scm" regular
        (file ,(source "guix/flakes/evaluator.scm")))
       ("support.scm" regular
        (file ,(source "guix/flakes/support.scm")))
       ("syntax.scm" regular
        (file ,(source "guix/flakes/syntax.scm"))))
     ("secrets" directory
      ("declaration.scm" regular
       (file ,(source "guix/secrets/declaration.scm"))))))))

(define %locked-guix-directory
  ;; A procedure that takes a store connection and a list of channels and
  ;; returns a directory that holds the Guix built from them, with its
  ;; 'bin/guix': what 'guix time-machine' runs.  The channels were
  ;; authenticated when they were locked.
  (make-parameter
   (lambda (store channels)
     ((module-ref (resolve-interface '(guix inferior))
                  'cached-channel-instance)
      store channels #:authenticate? #f))))

(define (node-channel session name node)
  "Return the channel NAME that is NODE at its locked commit."
  (channel (name name)
           (url (lock-node-location node (session-directory session)))
           (commit (lock-node-commit node))))

(define (instance-evaluator session instance)
  "Return four values for the evaluator of INSTANCE: the command that runs
(guix flakes evaluator), what tells its Guix from another for the cache (or
#f if nothing does), the version that Guix must report (or #f), and whether
it is the Guix that is running.

The input named 'guix' is the evaluator: that commit is built, with the
library inputs as its channels, the way 'guix time-machine' builds one.  A
flake without such an input is evaluated by the Guix that is running."
  (define store (session-store session))

  (define (remember . results)
    ;; A Guix is built, or looked up, once per instance.
    (hash-set! (session-evaluators session) (instance-id instance) results)
    (apply values results))

  (match (or (hash-ref (session-evaluators session) (instance-id instance))
             (find (lambda (edge) (eq? 'guix (lock-edge-name edge)))
                   (instance-edges instance)))
    ((? list? known)
     (apply values known))
    (#f
     (remember (list %guile "--no-auto-compile" "-c"
                     "(use-modules (guix flakes evaluator)) \
(run-flake-evaluator)")
               (guix-identity) #f #t))
    (edge
     (let* ((node      (edge-node session edge))
            (libraries (filter-map
                        (lambda (edge)
                          (let ((node (edge-node session edge)))
                            (and (eq? 'library (lock-edge-as edge))
                                 (not (eq? 'guix (lock-edge-name edge)))
                                 ;; A work tree has no commit to build.
                                 (not (lock-node-worktree? node))
                                 (node-channel session (lock-edge-name edge)
                                               node))))
                        (instance-edges instance)))
            (directory (canonicalize-path
                        ((%locked-guix-directory)
                         store
                         (cons (node-channel session 'guix node)
                               libraries))))
            (script    (add-text-to-store
                        store "flake-evaluator.scm"
                        "(use-modules (guix flakes evaluator))
(run-flake-evaluator)\n")))
       (remember (list (string-append directory "/bin/guix") "repl" "-q"
                       "-L" (evaluator-sources store) "--" script)
                 directory
                 (lock-node-commit node)
                 #f)))))

(define (guix-identity)
  "Return a string that changes whenever the modules of the running Guix do:
their directories when those are in the store, else a digest of the names,
sizes and modification times of the files."
  (define (root file path)
    (and=> (find (lambda (directory)
                   (file-exists? (string-append directory "/" file)))
                 path)
           canonicalize-path))

  (let ((roots (delete-duplicates
                (filter-map identity
                            (list (root "guix/flakes/evaluate.scm" %load-path)
                                  (root "guix/flakes/evaluate.go"
                                        %load-compiled-path))))))
    (if (every (lambda (directory)
                 (string-prefix? (string-append (%store-prefix) "/")
                                 directory))
               roots)
        (string-join roots ":")
        (bytevector->base16-string
         (sha256
          (string->utf8
           (object->string
            (append-map
             (lambda (directory)
               (append-map
                (lambda (sub)
                  (map (lambda (file)
                         (let ((stat (stat file)))
                           (list file (stat:size stat) (stat:mtime stat)
                                 (stat:mtimensec stat))))
                       (find-files (string-append directory "/" sub)
                                   "\\.(scm|go)$")))
                '("guix" "gnu")))
             roots))))))))

(define (results answers)
  "Return ANSWERS without what the evaluator says about itself."
  (remove (match-lambda
            (('guix . _) #t)
            (_ #f))
          answers))

(define* (converse session instance request to-evaluator from-evaluator
                   #:key decide version)
  "Send REQUEST to the evaluator of INSTANCE, answer its questions, and
return the list of its answers.  DECIDE, if given, is called with the file
names of the derivations that a command which is to act would build, and
returns whether it may.  VERSION, if given, is what the evaluator must say
its Guix is."
  (define (send datum)
    (write datum to-evaluator)
    (newline to-evaluator)
    (force-output to-evaluator))

  (define (input-handle name kind output)
    ;; The evaluator asks for an output of the flake input NAME: evaluate
    ;; that flake, which is an instance of its own.
    (let ((edge (find (lambda (edge) (eq? name (lock-edge-name edge)))
                      (instance-edges instance))))
      (unless (and edge (eq? 'flake (lock-edge-as edge)))
        (raise (formatted-message (G_ "'~a' is not a flake input") name)))
      (match (results (evaluate-instance session
                                         (edge-instance session edge)
                                         `(output ,kind ,output)))
        ((('output _ _ derivation metadata))
         `(handle ,derivation ,metadata)))))

  (send request)
  (let loop ((answers '()))
    (match (read from-evaluator)
      (('done) (reverse answers))
      (('input-output name kind output)
       (send (input-handle name kind output))
       (loop answers))
      ((? eof-object?)
       ;; It has said why on standard error.
       (raise (formatted-message (G_ "the evaluation of the flake failed"))))
      ((and answer ('derivations . names))
       (when decide
         (send (if (decide names) '(proceed) '(refuse))))
       (loop (cons answer answers)))
      ((and answer ('guix reported))
       (when (and version (not (equal? version reported)))
         (raise (formatted-message
                 (G_ "the lock pins Guix at ~a, but the Guix that was built \
from it says it is ~a")
                 version reported)))
       (loop (cons answer answers)))
      ((and answer ((or 'output 'entry 'absent) . _))
       (loop (cons answer answers)))
      (answer
       (raise (formatted-message
               (G_ "the evaluator said something unexpected: ~s")
               answer))))))

(define (edge-instance session edge)
  "Return the instance that EDGE leads to: the flake of its node, with the
node's own edges as inputs and the options that EDGE sets."
  (let ((node (edge-node session edge)))
    (instance (id (lock-node-id node))
              (tree (node-tree session node))
              (edges (lock-node-inputs node))
              (options (lock-edge-options edge))
              (revision (and (not (lock-node-worktree? node))
                             (lock-node-commit node))))))

(define (instance-request session instance flake want)
  "Return the request that asks the evaluator of INSTANCE, whose declaration
is FLAKE, for WANT."
  `((source . ,(instance-tree instance))
    (system . ,(session-system session))
    (target . ,(session-target session))
    (options . ,(typed-options flake (instance-options instance)))
    (revision . ,(instance-revision instance))
    (modules . ,(flake-modules flake))
    (inputs . ,(map (lambda (edge)
                      (let ((tree (node-tree session
                                             (edge-node session edge))))
                        (list (lock-edge-name edge)
                              (lock-edge-as edge)
                              tree
                              ;; The modules of 'guix' are the evaluator's
                              ;; own.
                              (and (eq? 'library (lock-edge-as edge))
                                   (not (eq? 'guix (lock-edge-name edge)))
                                   (library-directory tree)))))
                    (instance-edges instance)))
    (want . ,want)))

(define* (run-evaluator session instance want #:key acting? decide)
  "Evaluate WANT for INSTANCE in a new evaluator and return its answers.
With ACTING?, the process is not confined: WANT is a command that is to act
on this machine if DECIDE lets it (see 'converse')."
  (let* ((store (session-store session))
         (flake (read-flake
                 (or (regular-file (instance-tree instance) "flake.scm")
                     (raise (formatted-message
                             (G_ "'~a' has no flake.scm")
                             (instance-tree instance))))))
         (request (instance-request session instance flake want)))
    (let-values (((command identity version host?)
                  (instance-evaluator session instance)))
      (evaluator-starts (+ 1 (evaluator-starts)))
      (call-with-evaluator
       command
       (lambda (to-evaluator from-evaluator)
         (converse session instance request to-evaluator from-evaluator
                   #:decide decide #:version version))
       ;; The Guix that is running finds the two modules through its load
       ;; path; one that was built is told on its command line.
       #:load-path (if host? (list (evaluator-sources store)) '())
       #:guix? host?
       #:acting? acting?))))


;;;
;;; The evaluation cache.
;;;

(define %evaluations
  ;; Key -> answers, for the evaluations of this process.
  (make-hash-table))

(define (evaluation-key session instance want)
  "Return the key of the evaluation of WANT for INSTANCE, or #f if nothing
identifies the Guix that would evaluate it."
  (let-values (((command identity version host?)
                (instance-evaluator session instance)))
    (and identity
         (bytevector->base16-string
          (sha256
           (string->utf8
            (object->string
             (list 2                              ;format of the cache
                   identity
                   (instance-tree instance)
                   (instance-id instance)
                   (instance-options instance)
                   (flake-lock->sexp (session-lock session))
                   (session-system session) (session-target session)
                   want))))))))

(define (cache-file key)
  (string-append (cache-directory #:ensure? #f) "/flake-evaluations/" key))

(define (valid-answers? store answers)
  ;; Whether the derivations that ANSWERS name are still there.
  (every (match-lambda
           (('output kind name (? string? derivation) metadata)
            (and (derivation-path? derivation)
                 (valid-path? store derivation)))
           (('derivations . names)
            (every (lambda (name)
                     (and (string? name) (derivation-path? name)
                          (valid-path? store name)))
                   names))
           (((or 'entry 'absent 'guix) . _) #t)
           (_ #f))
         answers))

(define (cached-answers store key)
  (let ((file (cache-file key)))
    (and (file-exists? file)
         (match (false-if-exception (call-with-input-file file read))
           (('evaluation (? list? answers))
            (and (valid-answers? store answers) answers))
           (_ #f)))))

(define (store-answers! store key answers)
  (define (root! items root)
    ;; An evaluation that was done again replaces its roots.
    (for-each (lambda (link)
                (false-if-exception (delete-file link)))
              (cons root
                    (map (lambda (index)
                           (string-append root "-" (number->string index)))
                         (iota (length items)))))
    (register-root store items root))

  (let ((file (cache-file key)))
    (mkdir-p (dirname file))
    (with-atomic-file-output file
      (lambda (port)
        (write `(evaluation ,answers) port)
        (newline port)))
    ;; Keep the derivations: the cache is useless without them.
    (for-each (match-lambda
                (('output kind name derivation metadata)
                 (root! (list derivation)
                        (string-append file "-" (symbol->string kind)
                                       "-" (symbol->string name))))
                (('derivations . names)
                 (root! names (string-append file "-command")))
                (_ #f))
              answers)))

(define (evaluate-instance session instance want)
  "Return the answers of the evaluator of INSTANCE to WANT: from this
process's memory, from the cache on disk, or from a new evaluator."
  (let* ((store (session-store session))
         (key   (evaluation-key session instance want)))
    (or (and key (session-cache? session)
             (or (hash-ref %evaluations key)
                 (and=> (cached-answers store key)
                        (lambda (answers)
                          (hash-set! %evaluations key answers)
                          answers))))
        (let ((answers (run-evaluator session instance want)))
          (when key
            (store-answers! store key answers)
            (hash-set! %evaluations key answers))
          answers))))


;;;
;;; Entry points.
;;;

(define* (open-session store directory
                       #:key (system (%current-system)) target
                       (overrides '()) (cache? #t))
  "Return a session for the flake in DIRECTORY, and its instance.  Say on
the way what local checkouts are not what the lock uses."
  (let* ((directory (canonicalize-path directory))
         (flake     (read-flake (string-append directory "/flake.scm")))
         (lock      (effective-flake-lock directory #:overrides overrides)))
    (for-each (lambda (input)
                (unless (flake-lock-root-edge lock (flake-input-name input))
                  (raise (formatted-message
                          (G_ "guix.lock has no input '~a'; run 'guix flake \
lock'")
                          (flake-input-name input)))))
              (flake-inputs flake))
    (for-each (lambda (notice) (info (G_ "~a~%") notice))
              (lock-notices lock directory))
    (values (session (store store) (directory directory) (lock lock)
                     (system system) (target target)
                     (trees (make-hash-table))
                     (evaluators (make-hash-table)) (cache? cache?))
            (lambda (options)
              (instance (id "")
                        (tree (import-tracked-tree store directory))
                        (edges (flake-lock-inputs lock))
                        (options (append options
                                         (remove (lambda (entry)
                                                   (assq (car entry) options))
                                                 (read-local-options directory))))
                        (revision (tracked-tree-revision directory)))))))

(define* (flake-answers store directory want
                        #:key (options '()) (system (%current-system))
                        target (overrides '()) (cache? #t))
  (let-values (((session instance)
                (open-session store directory
                              #:system system #:target target
                              #:overrides overrides #:cache? cache?)))
    (results (evaluate-instance session (instance options) want))))

(define* (evaluate-flake store directory kind name
                         #:key (options '()) (system (%current-system))
                         target (overrides '()) (cache? #t))
  "Return the derivation of the output NAME of kind KIND of the flake in
DIRECTORY, for SYSTEM and TARGET.  OPTIONS is an alist of names of options of
the flake and their values, which may be text from a command line.
OVERRIDES redirects inputs for this run (see 'effective-flake-lock')."
  (match (flake-answers store directory `(output ,kind ,name)
                        #:options options #:system system #:target target
                        #:overrides overrides #:cache? cache?)
    ((('output _ _ derivation metadata))
     (read-derivation-from-file derivation))))

(define* (evaluate-flake-outputs store directory
                                 #:key (options '())
                                 (system (%current-system)) target
                                 (overrides '()) (cache? #t))
  "Return the outputs of the flake in DIRECTORY as a list of (KIND NAME
DERIVATION) lists, where DERIVATION is a file name, or #f for an output of a
kind that is not lowered.  Without CACHE?, evaluate anew whatever the cache
holds."
  (map (match-lambda
         (('output kind name derivation metadata)
          (list kind name derivation))
         (('entry kind name)
          (list kind name #f)))
       (flake-answers store directory '(all)
                      #:options options #:system system #:target target
                      #:overrides overrides #:cache? cache?)))

(define* (evaluate-flake-shell store directory name
                               #:key development? optional? bootstrap?
                               (options '()) (system (%current-system))
                               (overrides '()))
  "Evaluate what 'guix shell' enters for NAME in the flake of DIRECTORY: the
shell of that name, else the package of that name, or with DEVELOPMENT? the
development environment of that package.  Return two values: the derivation
of its profile and the alist of the environment variables it sets.  When
there is none, return #f and the empty list if OPTIONAL?, and raise an error
otherwise.  BOOTSTRAP? is the '--bootstrap' option of 'guix shell'."
  (match (flake-answers store directory
                        `(shell ,name ((development? . ,development?)
                                       (optional? . ,optional?)
                                       (bootstrap? . ,bootstrap?)))
                        #:options options #:system system
                        #:overrides overrides)
    ((('output _ _ derivation metadata))
     (values (read-derivation-from-file derivation)
             (or (assq-ref metadata 'environment) '())))
    ((('absent . _))
     (values #f '()))))

(define* (evaluate-flake-command store directory command kinds name
                                 arguments
                                 #:key (options '())
                                 (system (%current-system)) target
                                 (overrides '())
                                 act?)
  "Return the file names of the derivations that 'guix COMMAND ARGUMENTS'
builds for the output NAME of the flake in DIRECTORY, looked for among KINDS,
a list of kinds of outputs.  COMMAND is 'system, 'home or 'deploy, and
ARGUMENTS the arguments of the command without the flake reference.

With ACT?, also carry the command out: the same program then runs outside
the container, on this machine, computes the derivations again, and goes on
only if they are those the container computed.  Otherwise an error is
raised, since something outside the flake has a say in what it evaluates
to."
  (let-values (((session instance)
                (open-session store directory
                              #:system system #:target target
                              #:overrides overrides)))
    (let* ((instance (instance options))
           (want     (lambda (act?)
                       `(command ,command ,kinds ,name ,arguments ,act?)))
           (inside   (match (results (evaluate-instance session instance
                                                        (want #f)))
                       ((('derivations . names))
                        (answered-derivations names)))))
      (when act?
        (let ((agreed? #f))
          (run-evaluator session instance (want #t)
                         #:acting? #t
                         #:decide (lambda (outside)
                                    (set! agreed? (equal? inside outside))
                                    agreed?))
          (unless agreed?
            (raise (formatted-message
                    (G_ "not carrying this out: outside the container '~a' \
evaluates to something else than inside, so it depends on more than the \
flake and its lock")
                    name)))))
      inside)))

;;; evaluate.scm ends here

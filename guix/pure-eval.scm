;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (guix pure-eval)
  #:use-module ((guix config) #:select (%guile %git))
  #:use-module (guix store)
  #:use-module (guix derivations)
  #:use-module (guix diagnostics)
  #:use-module (guix i18n)
  #:use-module ((guix utils)
                #:select (%current-system call-with-temporary-directory))
  #:use-module (guix build utils)
  #:use-module ((gnu build linux-container)
                #:select (call-with-container %writable-/tmp
                          user-namespace-supported?
                          unprivileged-user-namespace-supported?
                          setgroups-supported?))
  #:use-module (gnu system file-systems)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 ftw)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-34)
  #:export (pure-eval-supported?
            import-tracked-tree
            tracked-file-predicate
            tracked-tree-revision

            git-top-level
            import-projects
            call-with-evaluator
            evaluate-in-container
            evaluator-main

            pure-build-derivations
            pure-shell-options
            pure-system-action
            build-and-print
            options-for-evaluator
            answered-derivations

            contained-build-derivations
            contained-shell-profile
            contained-system-derivations))

(define (store-file? file)
  (string-prefix? (string-append (%store-prefix) "/") file))

(define (guile-store-root)
  "Return the directory that holds the store item of the Guile that runs
Guix: the store for an installed Guix, another package manager's store when
Guix was built from a checkout with its tools.  Return #f when Guile does not
live in a store item, as with a distribution's /usr/bin/guile: nothing short
of the whole file system would make it run."
  (let* ((item (dirname (dirname %guile)))
         (name (basename item)))
    (and (> (string-length name) 33)
         (char=? #\- (string-ref name 32))
         (string-every (string->char-set "0123456789abcdfghijklmnpqrsvwxyz")
                       name 0 32)
         (dirname item))))

(define (pure-eval-supported?)
  "Whether evaluation can be confined: unprivileged Linux namespaces exist
and the Guile that runs Guix can be mounted without the rest of the host."
  (and (user-namespace-supported?)
       (unprivileged-user-namespace-supported?)
       (setgroups-supported?)
       (guile-store-root)
       #t))

(define (tracked-tree-revision directory)
  "Return the commit that is checked out in the Git work tree DIRECTORY, or
#f when tracked files below it have changes that are not committed."
  (define (git . arguments)
    (let* ((port   (apply open-pipe* OPEN_READ %git "-C" directory arguments))
           (output (get-string-all port)))
      (and (zero? (close-pipe port)) output)))

  (and (file-exists? (string-append directory "/.git"))
       (let ((changes (git "status" "--porcelain" "--untracked-files=no"
                           "--ignore-submodules=all" "--" ".")))
         (and changes
              (string-null? (string-trim-both changes))
              (and=> (git "rev-parse" "HEAD") string-trim-right)))))

(define (tracked-files directory)
  "Return the names, relative to DIRECTORY, of the files below it that are in
Git's index."
  (let* ((port   (open-pipe* OPEN_READ %git "-C" directory
                             "ls-files" "-z" "--" "."))
         (names  (string-split (get-string-all port) #\nul))
         (status (close-pipe port)))
    (unless (zero? status)
      (error "cannot enumerate tracked project tree" directory))
    (remove string-null? names)))

(define (tracked-file-predicate directory)
  "Return a predicate for 'add-to-store' and 'file-hash*' that selects, below
DIRECTORY, the files that Git tracks and the directories that lead to them.
DIRECTORY must be a canonical file name.  The path of a submodule is selected
as a directory and nothing below it is."
  (let ((prefix   (+ 1 (string-length directory)))
        (selected (make-hash-table)))
    (for-each (lambda (name)
                (let loop ((name name))
                  (unless (or (string=? name ".") (hash-ref selected name))
                    (hash-set! selected name #t)
                    (loop (dirname name)))))
              (tracked-files directory))
    (lambda (file stat)
      (hash-ref selected (string-drop file prefix)))))

(define (import-tracked-tree store directory)
  "Import into STORE the files below DIRECTORY that Git tracks, with the
contents they have in the work tree, and return the store item.  Untracked
and ignored files are never read."
  (let ((directory (canonicalize-path directory)))
    (add-to-store store "pure-eval-project" #t "sha256" directory
                  #:select? (tracked-file-predicate directory))))

(define* (mapping source #:optional (target source))
  (file-system
    (device source)
    (mount-point target)
    (type "none")
    (flags '(bind-mount read-only))
    (create-mount-point? #t)
    (check? #f)))

(define (exit-status status)
  (or (status:exit-val status)
      (+ 128 (or (status:term-sig status) 0))))


;;;
;;; Evaluation in a container.
;;;
;;; The evaluator is a fresh Guile process.  It sees the store, the daemon's
;;; socket, an empty /tmp, the modules of Guix, and the tracked files of the
;;; projects it was given, each at the place where its work tree is, so that
;;; every file name means inside what it means outside.  It gets an
;;; environment made from nothing, no network and a fixed host name.  What it
;;; evaluates is an S-expression passed as an argument; what comes back is
;;; one datum on a pipe of its own, apart from standard output.
;;;

(define (inside? file directory)
  (or (string=? file directory)
      (string-prefix? (string-append directory "/") file)))

(define (git-top-level directory)
  "Return the top-level directory of the Git work tree that contains
DIRECTORY, or #f if there is none."
  (and (file-exists? directory)
       (let* ((port   (parameterize ((current-error-port
                                      (%make-void-port "w")))
                        (open-pipe* OPEN_READ %git "-C" directory
                                    "rev-parse" "--show-toplevel")))
              (line   (read-line port))
              (status (close-pipe port)))
         (and (zero? status) (string? line) (not (string-null? line))
              (canonicalize-path line)))))

(define (module-directories)
  "Return the directories given with '-L', as absolute file names: those of
the package module path that 'GUIX_PACKAGE_PATH' did not put there."
  (let ((ambient (string-tokenize (or (getenv "GUIX_PACKAGE_PATH") "")
                                  (char-set-complement (char-set #\:)))))
    (filter-map (lambda (entry)
                  (and (string? entry)
                       (not (member entry ambient))
                       (file-exists? entry)
                       (canonicalize-path entry)))
                ((@ (gnu packages) %package-module-path)))))

(define* (import-projects store files #:key directory)
  "Import into STORE the tracked tree of each Git work tree that holds one of
FILES or a directory given with '-L'; also that of DIRECTORY, if it is given
and lies in a work tree apart from those.  Return a list of (TOP-LEVEL
. STORE-ITEM) pairs.  A file that is in no work tree is an error: nothing of
it could be shown to the evaluator."
  (define (top-level file)
    (or (git-top-level (if (file-is-directory? file) file (dirname file)))
        (raise (formatted-message
                (G_ "'~a' is not in a Git checkout; pure evaluation sees \
tracked files only")
                file))))

  (define required
    (delete-duplicates
     (append (map (lambda (file)
                    (if (file-exists? file)
                        (top-level (canonicalize-path file))
                        (raise (formatted-message
                                (G_ "'~a': no such file") file))))
                  files)
             (filter-map (lambda (directory)
                           (or (git-top-level directory)
                               (begin
                                 (warning (G_ "ignoring module directory \
'~a': it is not in a Git checkout~%")
                                          directory)
                                 #f)))
                         (module-directories)))))

  (define tops
    (sort (match (and directory (git-top-level directory))
            (#f required)
            (current
             (if (any (lambda (top)
                        (or (inside? top current) (inside? current top)))
                      required)
                 required
                 (cons current required))))
          string<?))

  (let loop ((tops tops) (result '()))
    (match tops
      (() (reverse result))
      ((top . rest)
       ;; A checkout cannot be mounted inside a tree that does not track it.
       (match (find (match-lambda
                      ((outer . _) (inside? top outer)))
                    result)
         ((outer . _)
          (raise (formatted-message
                  (G_ "'~a' is a checkout inside the checkout '~a'; pure \
evaluation cannot show both")
                  top outer)))
         (#f
          (loop rest
                (alist-cons top (import-tracked-tree store top) result))))))))

(define (guix-roots)
  "Return the directories outside the mounted stores from which this Guix
loads its own modules and their compiled forms: none for an installed Guix,
the source and build trees for one that runs from a checkout."
  (define (root path file)
    (and=> (find (lambda (directory)
                   (file-exists? (string-append directory "/" file)))
                 path)
           canonicalize-path))

  (remove (lambda (directory)
            (or (store-file? directory)
                (inside? directory (guile-store-root))))
          (delete-duplicates
           (filter-map identity
                       (list (root %load-path "guix/pure-eval.scm")
                             (root %load-compiled-path
                                   "guix/pure-eval.go"))))))

(define (daemon-socket-file)
  "Return the file name of the daemon's socket.  A daemon reached over the
network cannot be used: the container has no network."
  (let ((uri (%daemon-socket-uri)))
    (cond ((string-prefix? "/" uri) uri)
          ((string-prefix? "unix://" uri)
           (string-drop uri (string-length "unix://")))
          (else
           (raise (formatted-message
                   (G_ "pure evaluation needs a local build daemon, \
not '~a'")
                   uri))))))

(define (container-mounts socket projects)
  "Return the file systems of the evaluator's container: an empty /tmp, the
store, the store that holds Guile, the daemon's SOCKET, each of PROJECTS (a
list of (DIRECTORY . TREE) pairs) at DIRECTORY, and the modules of a Guix that
runs from a checkout."
  (define (project-of file)
    (find (match-lambda
            ((directory . _) (inside? file directory)))
          projects))

  (define (mountable? file)
    ;; A file inside a project can be mounted only where the tracked tree,
    ;; which is read-only, already has a place for it.
    (match (project-of file)
      (#f #t)
      ((directory . tree)
       (file-exists? (string-append tree
                                    (string-drop file
                                                 (string-length directory)))))))

  (define (required file)
    ;; The store, Guile and the socket must be there.
    (if (mountable? file)
        (mapping file)
        (match (project-of file)
          ((directory . _)
           (raise (formatted-message
                   (G_ "'~a' lies inside the checkout '~a', which does not \
track it; pure evaluation cannot show both")
                   file directory))))))

  (let ((guile-root (guile-store-root)))
    ;; A project comes before whatever may lie inside it.
    `(,%writable-/tmp
      ,@(map (match-lambda
               ((directory . tree) (mapping tree directory)))
             projects)
      ,(required (%store-prefix))
      ,@(if (string=? guile-root (%store-prefix))
            '()
            (list (required guile-root)))
      ,(required socket)
      ;; Only the modules: the rest of a checkout of Guix is none of the
      ;; evaluator's business.
      ,@(append-map (lambda (root)
                      (filter-map (lambda (name)
                                    (let ((file (string-append root "/"
                                                               name)))
                                      (and (file-exists? file)
                                           (mountable? file)
                                           (mapping file))))
                                  '("guix" "gnu" "guix.scm" "gnu.scm"
                                    "guix.go" "gnu.go")))
                    (guix-roots)))))

(define (evaluator-environment socket projects)
  "Return the whole environment of the evaluator, a list of strings.  Of the
load path it keeps what the container shows: the stores, the modules of Guix,
and the directories inside PROJECTS."
  (define (shown? directory)
    (or (store-file? directory)
        (and=> (guile-store-root) (cut inside? directory <>))
        (member directory (guix-roots))
        (any (match-lambda
               ((top . _) (inside? directory top)))
             projects)))

  (define (shown path)
    (delete-duplicates
     (filter-map (lambda (directory)
                   (and (file-exists? directory)
                        (let ((directory (canonicalize-path directory)))
                          (and (shown? directory) directory))))
                 path)))

  `("GUILE_AUTO_COMPILE=0"
    ,(string-append "GUILE_LOAD_PATH=" (string-join (shown %load-path) ":"))
    ,(string-append "GUILE_LOAD_COMPILED_PATH="
                    (string-join (shown %load-compiled-path) ":"))
    ;; Where a Guile that was not built by Guix finds the native parts of
    ;; its libraries.
    ,@(match (shown (string-tokenize (or (getenv "GUILE_EXTENSIONS_PATH") "")
                                     (char-set-complement (char-set #\:))))
        (() '())
        (directories
         (list (string-append "GUILE_EXTENSIONS_PATH="
                              (string-join directories ":")))))
    "HOME=/tmp"
    "TMPDIR=/tmp"
    ,(string-append "NIX_STORE_DIR=" (%store-prefix))
    ,(string-append "GUIX_DAEMON_SOCKET=" socket)
    ,@(match (shown (module-directories))
        (() '())
        (directories
         (list (string-append "GUIX_PACKAGE_PATH="
                              (string-join directories ":")))))))

(define (close-other-descriptors . keep)
  "Close every file descriptor above standard error except those in KEEP:
the evaluator must not inherit what the command had open."
  (for-each (lambda (name)
              (let ((descriptor (string->number name)))
                (when (and descriptor (> descriptor 2)
                           (not (memv descriptor keep)))
                  (false-if-exception (close-fdes descriptor)))))
            (or (scandir "/proc/self/fd")
                (map number->string (iota 1024)))))

(define (evaluator-main)
  "The entry point of the process that 'evaluate-in-container' starts:
evaluate the expression given as the argument and write (value RESULT) to
file descriptor 4."
  (match (command-line)
    ((_ expression)
     (let* ((port   (fdopen 4 "w"))
            (result (primitive-eval
                     (call-with-input-string expression read))))
       (write (list 'value result) port)
       (close-port port)))))

(define* (call-with-evaluator command proc
                              #:key
                              (projects '()) (directory "/") (load-path '())
                              (container? (pure-eval-supported?))
                              (guix? #t)
                              acting?)
  "Run COMMAND, a list of a program and its arguments, as an evaluator: a
process confined to a container, with an environment made from nothing.  Call
PROC with two ports, one that the process reads from its file descriptor 3
and one that it writes to through its file descriptor 4, and return what PROC
returns.  The process is ended if PROC leaves otherwise; that it ends with a
failure after PROC returned is an error.

PROJECTS is a list of (DIRECTORY . TREE) pairs as returned by
'import-projects': the process sees the store item TREE at DIRECTORY.  It
starts in DIRECTORY.  LOAD-PATH is a list of directories of the store that
come first in its load path.  Without GUIX?, the load path of the Guix that
is running is not handed down: COMMAND brings its own.

Without CONTAINER?, which is the case where containers are not available (no
user namespaces, as on the Hurd, or a Guile outside any store), the process
runs with the same scrubbed environment on the host's file system, and a
warning says so.

With ACTING?, the process is not an evaluator but the same program let loose
to act on this machine: it runs where the caller runs, with the caller's
environment and standard output, and only LOAD-PATH put first."
  (define socket (daemon-socket-file))

  (define (with-load-path variable)
    ;; LOAD-PATH comes before everything else.
    (if (and (pair? load-path)
             (string-prefix? "GUILE_LOAD_PATH=" variable))
        (string-append "GUILE_LOAD_PATH="
                       (string-join load-path ":") ":"
                       (string-drop variable
                                    (string-length "GUILE_LOAD_PATH=")))
        variable))

  (define environment
    (if acting?
        (let ((environment (map with-load-path (environ))))
          (if (or (null? load-path)
                  (any (cut string-prefix? "GUILE_LOAD_PATH=" <>)
                       environment))
              environment
              (cons (string-append "GUILE_LOAD_PATH="
                                   (string-join load-path ":"))
                    environment)))
        (map with-load-path
             (if guix?
                 (evaluator-environment socket projects)
                 (remove (lambda (variable)
                           (any (cut string-prefix? <> variable)
                                '("GUILE_LOAD_PATH="
                                  "GUILE_LOAD_COMPILED_PATH="
                                  "GUILE_EXTENSIONS_PATH="
                                  "GUIX_PACKAGE_PATH=")))
                         (evaluator-environment socket projects))))))

  ;; The processes made below are copies of this one, buffers included:
  ;; leave nothing in them that a copy would write a second time.
  (flush-all-ports)

  (match (list (pipe) (pipe))
    (((child-input . to-child) (from-child . child-output))
     (let* ((result #f)
            (child
             (lambda ()
               (close-port to-child)
               (close-port from-child)
               ;; Park both ends above the numbers they are to get, so that
               ;; neither is in the way of the other.
               (let ((input  (fcntl child-input F_DUPFD 10))
                     (output (fcntl child-output F_DUPFD 10)))
                 (dup2 input 3)
                 (dup2 output 4)
                 ;; What the evaluated code prints is for the user to read,
                 ;; not part of the result.
                 (unless acting?
                   (dup2 2 1))
                 (close-other-descriptors 3 4))
               (unless acting?
                 (chdir (if (file-exists? directory) directory "/")))
               (apply execle (car command) environment command)))
            (converse
             (lambda (pid)
               ;; Let go of the child's ends first: an evaluator that dies
               ;; must read as end of file.
               (close-port child-input)
               (close-port child-output)
               (set! result
                     (with-exception-handler
                         (lambda (exception)
                           (false-if-exception (kill pid SIGKILL))
                           (false-if-exception (waitpid pid))
                           (raise-exception exception))
                       (lambda ()
                         (call-with-values
                             (lambda () (proc to-child from-child))
                           list))
                       #:unwind? #t))
               (false-if-exception (close-port to-child))))
            (status
             (if (and container? (not acting?))
                 (call-with-container (container-mounts socket projects)
                   child
                   #:loopback-network? #f
                   ;; As the first process of its namespace the evaluator
                   ;; would ignore the signals relayed to it, C-c included.
                   #:child-is-pid1? #f
                   ;; This runs while the root can still be written to and
                   ;; the process still owns its namespaces.
                   #:populate-file-system
                   (lambda ()
                     (sethostname "localhost")
                     (false-if-exception (mkdir-p directory)))
                   #:process-spawned-hook converse)
                 (begin
                   (unless acting?
                     (warning (G_ "no container can be made here; \
evaluating with a scrubbed environment only~%")))
                   (match (primitive-fork)
                     (0 (dynamic-wind
                          (const #t)
                          child
                          (lambda () (primitive-_exit 127))))
                     (pid (converse pid)
                          (cdr (waitpid pid))))))))
       (close-port from-child)
       (unless (zero? (exit-status status))
         ;; The evaluator has reported what went wrong.
         (raise (formatted-message
                 (G_ "evaluation in the container failed"))))
       (apply values result)))))

(define* (evaluate-in-container expression
                                #:key (projects '()) (directory (getcwd))
                                (container? (pure-eval-supported?)))
  "Evaluate EXPRESSION, an S-expression, in a fresh Guile process (see
'call-with-evaluator' for PROJECTS, DIRECTORY and CONTAINER?) and return its
value, which must have a written form that 'read' takes back."
  (match (call-with-evaluator
          (list %guile "--no-auto-compile" "-c"
                "((@ (guix pure-eval) evaluator-main))"
                (object->string expression))
          (lambda (to-evaluator from-evaluator)
            (false-if-exception (read from-evaluator)))
          #:projects projects #:directory directory
          #:container? container?)
    (('value value) value)
    (_ (raise (formatted-message
               (G_ "evaluation in the container failed"))))))


;;;
;;; Commands.
;;;
;;; The host side of '--pure-eval' hands the options of the command to the
;;; evaluator, which runs the command's own code on them up to the
;;; derivations and returns their file names.  Building is the host's part.
;;;

(define (datum? object)
  "Whether OBJECT has a written form that 'read' takes back."
  (match object
    ((head . tail) (and (datum? head) (datum? tail)))
    (_ (or (null? object) (string? object) (symbol? object) (number? object)
           (boolean? object) (char? object) (keyword? object)))))

(define* (options-for-evaluator opts #:key (optional '()))
  "Return OPTS, the parsed options of a command, as the evaluator gets them:
without 'pure-eval?' and without the entries whose key is in OPTIONAL when
they have no written form.  Any other entry without one is an error: leaving
it out would change what is built."
  (filter-map (match-lambda
                (('pure-eval? . _) #f)
                ((key . value)
                 (cond ((datum? value) (cons key value))
                       ((memq key optional) #f)
                       (else
                        (raise (formatted-message
                                (G_ "the option that sets '~a' cannot be \
combined with pure evaluation")
                                key))))))
              opts))

(define (option-files opts keys)
  "Return the file names that OPTS holds under one of KEYS."
  (filter-map (match-lambda
                ((key . (? string? file))
                 (and (memq key keys) file))
                ((key _ (? string? file))         ;(load MODE FILE)
                 (and (memq key keys) file))
                (_ #f))
              opts))

(define (answered-derivations answer)
  "Return ANSWER, which the evaluator gave, if it is a list of derivation
file names in the store; anything else is an error.  The evaluated code can
reach the pipe, so the answer is checked like any input."
  (match answer
    (((? string? names) ...)
     (if (every (lambda (name)
                  (and (store-file? name) (derivation-path? name)
                       (file-exists? name)))
                names)
         names
         (raise (formatted-message
                 (G_ "the evaluator named something that is not a \
derivation")))))
    (_
     (raise (formatted-message
             (G_ "the evaluator gave no list of derivations"))))))

(define (expression-directory opts)
  "Return the current directory if OPTS holds an expression, which may name
files relative to it, and #f otherwise."
  (and (assq 'expression opts) (getcwd)))

(define (call-with-evaluation-errors command thunk)
  "Call THUNK the way COMMAND, a symbol, runs its body, so that errors are
reported as the command reports them, and end the process."
  (parameterize ((program-name command))
    ((@ (guix ui) call-with-error-handling) thunk)))

(define (notifier opts)
  ((@ (guix ui) build-notifier)
   #:use-substitutes? (assoc-ref opts 'substitutes?)
   #:verbosity (or (assoc-ref opts 'verbosity) 1) ;'guix system' has none
   #:dry-run? (assoc-ref opts 'dry-run?)))

(define (set-build-options store opts)
  ((@ (guix scripts build) set-build-options-from-command-line) store opts))

(define (call-with-status opts thunk)
  ((@@ (guix status) call-with-status-verbosity)
   (or (assoc-ref opts 'verbosity) 1) thunk))

;; 'guix build'.

(define (contained-build-derivations opts)
  "In the evaluator: return the file names of the derivations that OPTS, the
options of 'guix build', denote; or the symbol 'stopped' when a dry run ended
at a build that evaluation needs."
  (call-with-evaluation-errors 'build
   (lambda ()
     (call-with-status opts
       (lambda ()
         (with-store store
           (set-build-options store opts)
           (match (with-build-handler (notifier opts)
                    (parameterize (((@ (guix grafts) %graft?)
                                    (assoc-ref opts 'graft?)))
                      (map derivation-file-name
                           ((@ (guix scripts build) options->derivations)
                            store opts))))
             ((? list? names) names)
             (_ 'stopped))))))))

(define (pure-build-derivations store opts)
  "Return the derivations that OPTS, the options of 'guix build', denote,
computed in the container."
  (let ((projects (import-projects store
                                   (option-files opts '(file manifest))
                                   #:directory (expression-directory opts))))
    (match (evaluate-in-container
            `((@ (guix pure-eval) contained-build-derivations)
              ',(options-for-evaluator opts))
            #:projects projects)
      ('stopped (exit 0))
      (answer (map read-derivation-from-file
                   (answered-derivations answer))))))

;; 'guix shell'.

(define (contained-shell-profile opts)
  "In the evaluator: return the file name of the derivation of the profile
that OPTS, the options of 'guix shell', denote; or 'stopped'."
  (call-with-evaluation-errors 'shell
   (lambda ()
     (call-with-status opts
       (lambda ()
         (with-store store
           (set-build-options store opts)
           (match (with-build-handler (notifier opts)
                    ;; As 'guix-environment*' does around the same calls.
                    (parameterize (((@ (guix grafts) %graft?)
                                    (assoc-ref opts 'graft?)))
                      (let* ((system     (assoc-ref opts 'system))
                             (bootstrap? (assoc-ref opts 'bootstrap?))
                             (manifest
                              ((@ (guix scripts environment)
                                  options/resolve-packages)
                               store opts)))
                        (parameterize ((%guile-for-build
                                        ((@ (guix packages) package-derivation)
                                         store
                                         (if bootstrap?
                                             (@ (gnu packages bootstrap)
                                                %bootstrap-guile)
                                             ((@ (guix packages)
                                                 default-guile)))
                                         system)))
                          (derivation-file-name
                           (run-with-store store
                             ((@ (guix scripts environment)
                                 manifest->derivation)
                              manifest system bootstrap?)))))))
             ((? string? name) name)
             (_ 'stopped))))))))

(define (pure-shell-options opts)
  "If OPTS, the options of 'guix shell', ask for pure evaluation, return them
with the packages, files and manifests replaced by the profile they denote,
computed in the container and built here.  Return OPTS unchanged otherwise."
  (define (payload? option)
    (match option
      (((or 'package 'load 'manifest 'expression 'nesting?) . _) #t)
      (_ #f)))

  (if (and (assoc-ref opts 'pure-eval?)
           (not (assoc-ref opts 'profile))
           (any payload? opts))
      (call-with-evaluation-errors 'shell
       (lambda ()
         (call-with-status opts
           (lambda ()
             (with-store store
               (set-build-options store opts)
               (let* ((projects (import-projects
                                 store (option-files opts '(load manifest))
                                 #:directory (expression-directory opts)))
                      (name (evaluate-in-container
                             `((@ (guix pure-eval) contained-shell-profile)
                               ',(options-for-evaluator
                                  opts
                                  ;; These say how to run the command,
                                  ;; not what the profile holds.
                                  #:optional '(inherit-regexps
                                               environment-variables
                                               file-system-mapping
                                               symlinks exec)))
                             #:projects projects)))
                 (when (eq? name 'stopped)
                   (exit 0))
                 (let ((drv (read-derivation-from-file
                             (first (answered-derivations (list name))))))
                   (with-build-handler (notifier opts)
                     (build-derivations store (list drv)))
                   (when (assoc-ref opts 'dry-run?)
                     (exit 0))
                   (alist-cons 'profile (derivation->output-path drv)
                               (remove payload? opts)))))))))
      opts))

;; 'guix system'.

(define (contained-system-derivations action args opts)
  "In the evaluator: carry out ACTION of 'guix system' on ARGS and OPTS as
far as the derivations, and return their file names."
  (let* ((printed
          (with-output-to-string
            (lambda ()
              (call-with-evaluation-errors 'system
               (lambda ()
                 (call-with-status opts
                   (lambda ()
                     ;; As 'guix-system' does around the same call.
                     (parameterize (((@ (guix grafts) %graft?)
                                     (assoc-ref opts 'graft?)))
                       ((@ (guix scripts system) process-action)
                        action args
                        (alist-cons 'derivations-only? #t opts))))))))))
         (lines (remove string-null? (string-split printed #\newline))))
    ;; With '--derivation' the command prints derivation file names and
    ;; nothing else; whatever else is there, the project printed it.
    (for-each (lambda (line)
                (unless (derivation-path? line)
                  (display line (current-error-port))
                  (newline (current-error-port))))
              lines)
    (filter derivation-path? lines)))

(define (build-and-print store names opts)
  "Build the derivations whose file names are NAMES and print what was
built, as a command that only builds does: with '--derivation' print NAMES
instead, with '--dry-run' say what would be built, and with '--root' register
the first result."
  (if (assoc-ref opts 'derivations-only?)
      (for-each (cut format #t "~a~%" <>) names)
      (let ((drvs (map read-derivation-from-file names)))
        (with-build-handler (notifier opts)
          (build-derivations store drvs)
          (for-each (lambda (drv)
                      (format #t "~a~%" (derivation->output-path drv)))
                    drvs)
          (match (assoc-ref opts 'gc-root)
            (#f #t)
            (root
             ((@ (guix scripts build) register-root)
              store
              (list (derivation->output-path (first drvs)))
              root)))))))

(define (pure-system-action action args opts)
  "Carry out ACTION of 'guix system' on ARGS and OPTS, with the evaluation in
the container: build what the action builds and print it."
  (when (memq action '(init reconfigure))
    (raise (formatted-message
            (G_ "'~a' acts on this machine and cannot be confined; pure \
evaluation is for the actions that only build")
            action)))
  (with-store store
    (set-build-options store opts)
    (let* ((projects (import-projects
                      store
                      (match args
                        (((? string? file) . _)
                         (if (assoc-ref opts 'expression) '() (list file)))
                        (_ '()))
                      #:directory (expression-directory opts)))
           (names (answered-derivations
                   (evaluate-in-container
                    `((@ (guix pure-eval) contained-system-derivations)
                      ',action ',args
                      ',(options-for-evaluator
                         opts
                         ;; Only 'reconfigure' uses it.
                         #:optional '(validate-reconfigure)))
                    #:projects projects))))
      (build-and-print store names opts))))

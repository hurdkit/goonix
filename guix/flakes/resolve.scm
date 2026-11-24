;;; goonix: from the inputs a flake declares to its lock.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (guix flakes resolve)
  #:use-module (guix flakes syntax)
  #:use-module (guix flakes lock)
  #:use-module (guix flakes checkout)
  #:use-module (guix diagnostics)
  #:use-module (guix i18n)
  #:use-module (guix base16)
  #:use-module (guix records)
  #:use-module ((guix utils) #:select (cache-directory))
  #:use-module ((guix build utils) #:select (mkdir-p))
  #:use-module (gcrypt hash)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-34)
  #:export (resolve-flake-lock
            lock-flake
            effective-flake-lock
            read-local-overrides
            read-local-options
            parse-input-override

            lock-node-tree
            lock-node-location
            lock-notices
            flake-metadata))

;;; Commentary:
;;;
;;; Resolving reads declarations and fetches trees.  It evaluates nothing:
;;; 'flake.scm', 'guix.lock' and '.guix-channel' are read as data.
;;;
;;; The inputs of one flake are resolved in two steps: each is fetched, then
;;; each is descended into.  So an input can follow any of its siblings, and
;;; the inputs of the flake that owns the lock are all known before anything
;;; below them looks for one to follow.
;;;
;;; Code:

(define (lock-file directory)
  (string-append directory "/guix.lock"))

(define (git-origin url)
  "Return the identity of the repository at URL, without the variations of
spelling that name one repository."
  (let* ((url (string-trim-right url #\/))
         (url (if (string-suffix? ".git" url)
                  (string-drop-right url 4)
                  url)))
    (cons 'git url)))

(define (absolute-path path base)
  "Return PATH if it is absolute, and PATH below BASE otherwise.  BASE is #f
for a flake that was not taken from a directory."
  (cond ((string-prefix? "/" path) path)
        (base (string-append base "/" path))
        (else
         (raise (formatted-message
                 (G_ "local input '~a' is relative, but the flake that \
names it comes from a repository")
                 path)))))

(define (input-origin input base)
  "Return the identity of the repository of INPUT, declared by a flake in
BASE, or #f if it cannot be told."
  (case (flake-input-type input)
    ((git) (git-origin (flake-input-url input)))
    ((local)
     (let ((path (flake-input-path input)))
       (and (or base (string-prefix? "/" path))
            (let ((path (absolute-path path base)))
              (cons 'local (if (file-exists? path)
                               (canonicalize-path path)
                               path))))))
    (else #f)))

(define (channel-inputs file)
  "Return as inputs the dependencies that FILE, a '.guix-channel', declares.
The file is read as data."
  (define (dependency->input datum)
    (match datum
      (('channel . properties)
       (let ((value (lambda (key)
                      (match (assq key properties)
                        ((_ value) value)
                        (_ #f)))))
         (unless (and (symbol? (value 'name)) (string? (value 'url)))
           (error "invalid dependency in .guix-channel" datum))
         (flake-input
          (name (value 'name)) (type 'git) (url (value 'url))
          (branch (value 'branch)) (commit (value 'commit))
          (as 'library)
          (introduction
           (match (value 'introduction)
             (('channel-introduction . fields)
              (match (list (assq 'commit fields) (assq 'signer fields))
                ((('commit commit) ('signer signer))
                 `((commit ,commit) (signer ,signer)))
                (_ #f)))
             (_ #f))))))
      (_ (error "invalid dependency in .guix-channel" datum))))

  (match (read-data-file file)
    (('channel ('version 0) . properties)
     (match (assq 'dependencies properties)
       (#f '())
       ((_ . dependencies) (map dependency->input dependencies))))
    (_ (error "unsupported .guix-channel file" file))))

(define (tree-declarations tree)
  "Read what TREE declares, while its files are there.  Return three values:
what the tree is ('flake, 'library or 'source), the inputs it declares, and
the S-expression of the lock it carries, or #f."
  (let ((flake   (tree-file tree "flake.scm"))
        (channel (tree-file tree ".guix-channel"))
        (lock    (tree-file tree "guix.lock")))
    (values (cond (flake 'flake) (channel 'library) (else 'source))
            (cond (flake (flake-inputs (read-flake flake)))
                  (channel (channel-inputs channel))
                  (else '()))
            (and lock (read-data-file lock)))))


;;;
;;; Resolution.
;;;

;; One input of a flake, between its fetch and the making of its edge.
(define-record-type* <entry> entry make-entry
  entry?
  (declared  entry-declared)              ;the <flake-input> as the flake has it
  (input     entry-input (default #f))    ;the same after replacement
  (base      entry-base (default #f))     ;directory that INPUT is relative to
  ;; The node that the edge leads to: one made for this input, an ancestor
  ;; when the input closes a cycle, or one the parent pointed to.
  (node      entry-node)
  (kind      entry-kind)                  ;the kind of the edge
  (target    entry-target (default #f))
  (as        entry-as (default #f))
  ;; For a node made for this input, what its tree declares and carries.
  (new?      entry-new? (default #f))
  (inputs    entry-inputs (default '()))
  (carried   entry-carried (default #f))  ;the S-expression of its guix.lock
  (directory entry-directory (default #f)) ;where a local tree is, else #f
  (key       entry-key (default #f))      ;(ORIGIN . COMMIT)
  (old       entry-old (default #f))      ;the node the previous lock had
  ;; The inputs of the flake that wrote INPUT, when that is not the flake
  ;; that declares it: what INPUT says its own inputs follow is looked up
  ;; there.
  (siblings  entry-siblings (default #f)))

(define* (resolve-flake-lock directory
                             #:key previous (update '()) (overrides '()))
  "Return the lock of the flake in DIRECTORY.  PREVIOUS is the lock it had,
or #f: an input whose declaration still matches keeps its commit, and its
tree must still have the recorded hash.  UPDATE is #t, to ignore PREVIOUS, or
a list of names of inputs of the flake to resolve anew, with everything below
them.  OVERRIDES is an alist of names of inputs of the flake and the
<flake-input> that replaces the source of each."
  (define root (canonicalize-path directory))

  (define nodes (make-hash-table))                ;ID -> <lock-node>
  (define trees (make-hash-table))                ;ID -> what its tree is
  (define order '())                              ;IDs, last made first

  (define (fresh-id name)
    (let ((base (if (symbol? name) (symbol->string name) name)))
      (let loop ((n 1))
        (let ((id (if (= n 1)
                      base
                      (string-append base "-" (number->string n)))))
          (if (hash-ref nodes id) (loop (+ n 1)) id)))))

  (define (add-node! node what)
    (hash-set! nodes (lock-node-id node) node)
    (hash-set! trees (lock-node-id node) what)
    (set! order (cons (lock-node-id node) order))
    (lock-node-id node))

  (define (set-inputs! id edges)
    (hash-set! nodes id
               (lock-node (inherit (hash-ref nodes id)) (inputs edges))))

  (define (recorded-path absolute)
    ;; A path inside the flake's directory is recorded relative to it, so
    ;; that the lock does not name where this checkout happens to be.
    (cond ((string=? absolute root) ".")
          ((string-prefix? (string-append root "/") absolute)
           (string-drop absolute (+ 1 (string-length root))))
          (else absolute)))

  (define (local-directory input base)
    (canonicalize-path (absolute-path (flake-input-path input) base)))

  (define (same-declaration? input base old)
    ;; Whether OLD, a node of the previous lock, was made from what INPUT
    ;; still says.
    (and (eq? (flake-input-type input) (lock-node-type old))
         (case (flake-input-type input)
           ((git) (equal? (git-origin (flake-input-url input))
                          (git-origin (lock-node-url old))))
           ((local) (equal? (recorded-path (local-directory input base))
                            (lock-node-path old))))
         (equal? (flake-input-branch input) (lock-node-branch old))
         (equal? (flake-input-tag input) (lock-node-tag old))
         (eq? (flake-input-worktree? input) (lock-node-worktree? old))
         (or (not (flake-input-commit input))
             (string=? (flake-input-commit input) (lock-node-commit old)))))

  (define (other-lock-input input base)
    ;; INPUT says (same-as SOURCE NAME): return the input that the lock of
    ;; the flake at SOURCE has under NAME, as a declaration with its commit.
    (match (flake-input-same-as input)
      ((source name)
       (let*-values (((other-base other)
                      (if (or (string-prefix? "/" source)
                              (string-prefix? "." source))
                          (let ((path (canonicalize-path
                                       (absolute-path source base))))
                            (values path
                                    (read-flake-lock (lock-file path))))
                          (let ((tree (fetch-git-tree source)))
                            (values #f
                                    (read-flake-lock
                                     (or (tree-file tree "guix.lock")
                                         (raise (formatted-message
                                                 (G_ "'~a' has no guix.lock")
                                                 source))))))))
                     ((edge)
                      (or (flake-lock-root-edge other name)
                          (raise (formatted-message
                                  (G_ "the lock of '~a' has no input '~a'")
                                  source name))))
                     ((node)
                      (flake-lock-node other (lock-edge-node edge))))
         (flake-input
          (inherit input)
          (type (lock-node-type node))
          (url (lock-node-url node))
          (path (and (lock-node-path node)
                     (absolute-path (lock-node-path node) other-base)))
          (branch (lock-node-branch node)) (tag (lock-node-tag node))
          (commit (lock-node-commit node))
          (worktree? (lock-node-worktree? node))
          (as (or (flake-input-as input) (lock-edge-as edge)))
          (same-as #f))))))

  (define (fetch input base old)
    ;; Fetch INPUT, declared by a flake in BASE, at the commit of OLD if
    ;; there is one, and return the tree.
    (when (and (eq? 'local (flake-input-type input)) (not base))
      ;; Whoever publishes a flake does not get to name directories of the
      ;; machine that uses it.
      (raise (formatted-message
              (G_ "input '~a' is a local path, '~a', in a flake that comes \
from a repository")
              (flake-input-name input) (flake-input-path input))))
    (let* ((commit (or (flake-input-commit input)
                       (and old (lock-node-commit old))))
           (tree   (case (flake-input-type input)
                     ((git)
                      (fetch-git-tree (flake-input-url input)
                                      #:branch (flake-input-branch input)
                                      #:tag (flake-input-tag input)
                                      #:commit commit))
                     ((local)
                      (fetch-local-tree
                       (absolute-path (flake-input-path input) base)
                       #:commit commit
                       #:worktree? (flake-input-worktree? input))))))
      (when (and old (lock-node-tree-hash old)
                 (not (equal? (tree-hash tree) (lock-node-tree-hash old))))
        (raise (formatted-message
                (G_ "input '~a': the files of commit ~a do not have the \
hash that the lock records")
                (flake-input-name input) (tree-commit tree))))
      tree))

  (define (authentication input tree old)
    ;; Authenticate TREE if INPUT has an introduction, unless OLD records
    ;; that this very commit was authenticated from the same introduction.
    (match (flake-input-introduction input)
      (#f #f)
      (introduction
       (unless (and old
                    (equal? introduction (lock-node-authentication old))
                    (string=? (tree-commit tree) (lock-node-commit old)))
         (authenticate-tree tree introduction))
       introduction)))

  (define (graft other other-base)
    ;; Copy the graph of OTHER, the lock that a pinned input carries, into
    ;; this one, and return the edges of its flake.  Nothing is fetched:
    ;; the commits and hashes are those the input recorded.
    (define copied (make-hash-table))             ;ID there -> ID here

    (define (copy-node id)
      (or (hash-ref copied id)
          (let* ((node (flake-lock-node other id))
                 (new  (fresh-id id)))
            (hash-set! copied id new)
            (add-node! (lock-node
                        (inherit node)
                        (id new)
                        (path (and (lock-node-path node)
                                   (recorded-path
                                    (absolute-path (lock-node-path node)
                                                   other-base))))
                        (inputs '()))
                       #f)
            (set-inputs! new (map copy-edge (lock-node-inputs node)))
            new)))

    (define (copy-edge edge)
      (lock-edge (inherit edge) (node (copy-node (lock-edge-node edge)))))

    (map (lambda (edge)
           (lock-edge (inherit (copy-edge edge)) (kind 'pinned)))
         (flake-lock-inputs other)))

  (define (fetch-entry declared decision old ancestors pinned?)
    ;; Return the entry of DECLARED, an input that DECISION, from the flake
    ;; that uses the tree it is declared in, lets stand (#f), points at a
    ;; node (to ID KIND TARGET), or replaces (replace INPUT BASE KIND
    ;; TARGET SIBLINGS), where BASE is the directory INPUT is relative to and
    ;; SIBLINGS the inputs of the flake that wrote it, or #f.
    (match decision
      (('to id kind target)
       (entry (declared declared) (node id) (kind kind) (target target)
              (as (or (flake-input-as declared) (hash-ref trees id)))))
      (('replace input base kind target siblings)
       (let*-values
           (((input kind target)
             (if (eq? 'same-as (flake-input-type input))
                 (values (other-lock-input input base)
                         'same-as (flake-input-same-as input))
                 (values input kind target)))
            ((old)  (and old (same-declaration? input base old) old))
            ((tree) (fetch input base old))
            ((what inputs carried) (tree-declarations tree))
            ((key)  (cons (input-origin input base) (tree-commit tree))))
         (match (assoc key ancestors)
           ((_ . id)
            ;; This tree is being resolved further up: a cycle.
            (entry (declared declared) (node id) (kind kind) (target target)
                   (as (or (flake-input-as input) (hash-ref trees id)))))
           (#f
            (let ((as (or (flake-input-as input)
                          (if (eq? what 'source)
                              (raise (formatted-message
                                      (G_ "input '~a' has neither a \
flake.scm nor a .guix-channel; say (as source) or (as library)")
                                      (flake-input-name declared)))
                              what)))
                  (directory (and (eq? 'local (flake-input-type input))
                                  (local-directory input base))))
              (when (and (eq? as 'flake) (not (eq? what 'flake)))
                (raise (formatted-message
                        (G_ "input '~a' is used as a flake but has no \
flake.scm")
                        (flake-input-name declared))))
              (entry
               (declared declared) (input input) (base base)
               (node (add-node!
                      (lock-node
                       (id (fresh-id (flake-input-name declared)))
                       (type (flake-input-type input))
                       (url (flake-input-url input))
                       (path (and directory (recorded-path directory)))
                       (branch (flake-input-branch input))
                       (tag (flake-input-tag input))
                       (commit (tree-commit tree))
                       (tree-hash (tree-hash tree))
                       (worktree? (tree-worktree? tree))
                       (authentication (authentication input tree old)))
                      what))
               (kind kind) (target target) (as as)
               (new? #t)
               (inputs (if (eq? as 'source) '() inputs))
               (carried carried) (directory directory)
               (key key) (old old) (siblings siblings)))))))))

  (define (entry->edge entry)
    (let ((declared (entry-declared entry)))
      (when (and (memq (entry-as entry) '(flake library))
                 (eq? 'source (hash-ref trees (entry-node entry))))
        (raise (formatted-message
                (G_ "input '~a' is used as a ~a, but its tree is only a \
source")
                (flake-input-name declared) (entry-as entry))))
      (lock-edge (name (flake-input-name declared))
                 (node (entry-node entry))
                 (kind (entry-kind entry))
                 (target (entry-target entry))
                 (as (entry-as entry))
                 (options (flake-input-options declared)))))

  (define* (resolve-inputs inputs base old-edges decide ancestors pinned?
                           #:key (keep-old? (const #t)) (known! (const #t)))
    ;; Resolve INPUTS, the inputs of one flake in BASE, and return its
    ;; edges.  OLD-EDGES are the edges the previous lock has for that
    ;; flake; KEEP-OLD? tells, for a name, whether to look there.  DECIDE
    ;; takes an input and returns the decision of the flake that uses this
    ;; one (see 'fetch-entry'), or #f.  ANCESTORS is an alist of the
    ;; (ORIGIN . COMMIT) and the ID of each node on the way down.  KNOWN!
    ;; is called with the entries once all inputs are fetched.
    (define (old-node name)
      (and previous (keep-old? name)
           (and=> (find (lambda (edge) (eq? name (lock-edge-name edge)))
                        old-edges)
                  (lambda (edge)
                    (flake-lock-node previous (lock-edge-node edge))))))

    ;; Step one: fetch each input.
    (define entries
      (map (lambda (input)
             (fetch-entry input
                          (or (decide input)
                              `(replace ,input ,base
                                        ,(if pinned? 'pinned 'direct)
                                        #f #f))
                          (old-node (flake-input-name input))
                          ancestors pinned?))
           inputs))

    (define siblings                              ;name -> ID
      (map (lambda (entry)
             (cons (flake-input-name (entry-declared entry))
                   (entry-node entry)))
           entries))

    (known! entries)

    ;; Step two: descend into the trees that were made for these inputs.
    (for-each
     (lambda (entry)
       (when (entry-new? entry)
         (let* ((input   (entry-input entry))
                (pinned? (or pinned? (flake-input-pinned? input)))
                (old     (entry-old entry)))
           (set-inputs!
            (entry-node entry)
            (if (and (flake-input-pinned? input) (entry-carried entry))
                (graft (sexp->flake-lock (entry-carried entry))
                       (entry-directory entry))
                (resolve-inputs
                 (entry-inputs entry) (entry-directory entry)
                 (if old (lock-node-inputs old) '())
                 (child-decision input (entry-base entry)
                                 (entry-inputs entry) (entry-directory entry)
                                 (or (entry-siblings entry) siblings)
                                 pinned?)
                 (alist-cons (entry-key entry) (entry-node entry) ancestors)
                 pinned?
                 ;; Below a tree that is new, nothing is kept.
                 #:keep-old? (const (->bool old))))))))
     entries)

    (map entry->edge entries))

  (define root-origins '())             ;((ORIGIN NAME . ID) ...)

  (define (root-follow input base)
    ;; Return the ID of the input of the flake that INPUT follows by
    ;; default: the one of the same repository.  When several are, the one
    ;; of the same name; failing that, none.
    (let* ((origin  (input-origin input base))
           (matches (if origin
                        (filter (match-lambda
                                  ((candidate . _) (equal? candidate origin)))
                                root-origins)
                        '())))
      (match matches
        (() #f)
        (((_ _ . id)) id)
        (several
         (any (match-lambda
                ((_ name . id)
                 (and (eq? name (flake-input-name input)) id)))
              several)))))

  (define (child-decision parent parent-base inputs base siblings pinned?)
    ;; Return the 'decide' procedure for INPUTS, which the tree of PARENT
    ;; declares from BASE.  PARENT is an input of a flake in PARENT-BASE
    ;; whose inputs are SIBLINGS, an alist of names and IDs.
    (define names (map flake-input-name inputs))

    (for-each (lambda (name)
                (unless (memq name names)
                  (raise (formatted-message
                          (G_ "input '~a' has no input '~a' to follow or \
replace")
                          (flake-input-name parent) name))))
              (append (map car (flake-input-follows parent))
                      (map car (flake-input-overrides parent))))

    (lambda (input)
      (let ((name (flake-input-name input)))
        (cond ((assq name (flake-input-follows parent))
               => (match-lambda
                    ((_ . ours)
                     (match (assq ours siblings)
                       ((_ . id) `(to ,id followed ,ours))
                       (#f
                        (raise (formatted-message
                                (G_ "'~a' of input '~a' is to follow '~a', \
which is not an input of the flake that says so")
                                name (flake-input-name parent) ours)))))))
              ((assq name (flake-input-overrides parent))
               => (lambda (spec)
                    `(replace ,(sexp->input spec) ,parent-base
                              replaced ,(cdr spec) ,siblings)))
              ((and (not pinned?) (root-follow input base))
               => (lambda (id) `(to ,id followed #f)))
              (else #f)))))

  (define (root-decision input)
    (match (assq (flake-input-name input) overrides)
      (#f #f)
      ((_ . override)
       ;; The override gives the source; what the flake says about the
       ;; input otherwise stays.
       `(replace ,(flake-input
                   (inherit input)
                   (type (flake-input-type override))
                   (url (flake-input-url override))
                   (path (flake-input-path override))
                   (branch (flake-input-branch override))
                   (tag (flake-input-tag override))
                   (commit (flake-input-commit override))
                   (worktree? (flake-input-worktree? override))
                   (as (or (flake-input-as override) (flake-input-as input)))
                   (same-as #f))
                 ,root replaced
                 ,(if (eq? 'git (flake-input-type override))
                      `(git ,(flake-input-url override))
                      `(local ,(flake-input-path override)))
                 #f))))

  (let* ((flake    (read-flake (string-append root "/flake.scm")))
         (declared (flake-inputs flake))
         (names    (map flake-input-name declared))
         (updated  (if (list? update) update '())))
    (for-each (lambda (name)
                (unless (memq name names)
                  (raise (formatted-message
                          (G_ "the flake has no input '~a'") name))))
              (append (map car overrides) updated))

    (let ((edges
           (resolve-inputs
            declared root
            (if previous (flake-lock-inputs previous) '())
            root-decision '() #f
            #:keep-old? (lambda (name)
                          (not (or (eq? update #t) (memq name updated))))
            ;; What is below the inputs of the flake follows them by
            ;; repository: both the one the flake names and, for an
            ;; overridden input, the one that took its place.
            #:known!
            (lambda (entries)
              (set! root-origins
                    (append-map
                     (lambda (entry)
                       (let ((name (flake-input-name (entry-declared entry)))
                             (id   (entry-node entry)))
                         (map (lambda (origin) (cons* origin name id))
                              (delete-duplicates
                               (filter identity
                                       (list (input-origin
                                              (entry-declared entry) root)
                                             (and (entry-input entry)
                                                  (input-origin
                                                   (entry-input entry)
                                                   (entry-base entry)))))))))
                     entries))))))
      (flake-lock
       (inputs edges)
       (nodes (map (lambda (id) (hash-ref nodes id))
                   (reverse order)))))))


;;;
;;; The lock of a flake, on disk and in effect.
;;;

(define* (lock-flake directory #:key (update '()))
  "Resolve the lock of the flake in DIRECTORY, keeping what its guix.lock
pins unless UPDATE says otherwise (see 'resolve-flake-lock'), and write it if
it differs from the file.  Return the lock."
  (let* ((file     (lock-file directory))
         (previous (and (file-exists? file) (read-flake-lock file)))
         (lock     (resolve-flake-lock directory
                                       #:previous previous #:update update))
         (text     (flake-lock->string lock)))
    (unless (and (file-exists? file)
                 (string=? text (call-with-input-file file get-string-all)))
      (write-flake-lock lock file))
    lock))

(define (parse-input-override name spec)
  "Return the <flake-input> that the text SPEC gives for the input NAME: a
path, or the fields of an input as in flake.scm, such as (git \"URL\")
(branch \"NAME\")."
  (sexp->input
   (cons name
         (if (string-prefix? "(" (string-trim spec))
             (read-data-string (string-append "(" spec ")"))
             `((local ,spec))))))

(define (read-local-members directory)
  "Return the INPUTS and OPTIONS members of DIRECTORY's local data file."
  (let ((file (string-append directory "/flake.local.scm")))
    (if (file-exists? file)
        (match (read-data-file file)
          (('flake-local ('version 1) members ...)
           (for-each (lambda (member)
                       (match member
                         (((or 'inputs 'options) . _) #t)
                         (_ (raise (formatted-message
                                    (G_ "~a: unknown local member") file)))))
                     members)
           (when (> (length (filter (lambda (member)
                                     (and (pair? member) (eq? 'options (car member))))
                                   members)) 1)
             (raise (formatted-message (G_ "~a: duplicate options member") file)))
           (when (> (length (filter (lambda (member)
                                     (and (pair? member) (eq? 'inputs (car member))))
                                   members)) 1)
             (raise (formatted-message (G_ "~a: duplicate inputs member") file)))
           (values (or (assq 'inputs members) '(inputs))
                   (or (assq 'options members) '(options))))
          (_ (raise (formatted-message
                     (G_ "~a: expected (flake-local (version 1) ...)") file))))
        (values '(inputs) '(options)))))

(define (read-local-options directory)
  "Return the data-only local options in DIRECTORY's flake.local.scm."
  (let-values (((inputs options) (read-local-members directory)))
    (let ((file (string-append directory "/flake.local.scm")))
      (map (lambda (datum)
             (match datum
               (((? symbol? name) value) (cons name value))
               (_ (raise (formatted-message
                          (G_ "~a: expected (NAME VALUE) local option") file)))))
           (cdr options)))))

(define (read-local-overrides directory)
  "Return the overrides of 'flake.local.scm' in DIRECTORY, an alist of names
and <flake-input> records; the empty list when there is no such file."
  (let-values (((inputs options) (read-local-members directory)))
    (map (lambda (datum)
           (let ((input (sexp->input datum)))
             (cons (flake-input-name input) input)))
         (cdr inputs))))

(define (overrides-key directory overrides)
  ;; What an effective lock depends on: the flake, its lock, and what the
  ;; overrides say.
  (define (contents file)
    (if (file-exists? file)
        (call-with-input-file file get-string-all)
        ""))

  (bytevector->base16-string
   (sha256
    (string->utf8
     (object->string
      (list directory
            (contents (string-append directory "/flake.scm"))
            (contents (lock-file directory))
            (map (match-lambda
                   ((name . input) (flake-input->sexp input)))
                 overrides)))))))

(define* (effective-flake-lock directory #:key (overrides '()) update?)
  "Return the lock that commands use for the flake in DIRECTORY: its
guix.lock, or, when 'flake.local.scm' or OVERRIDES (an alist of names and
<flake-input> records, which win) redirect inputs, the lock that results.
That one is kept in the cache directory and guix.lock is left alone.  With
UPDATE?, resolve the redirected inputs again."
  (let* ((directory (canonicalize-path directory))
         (file      (lock-file directory))
         (committed (and (file-exists? file) (read-flake-lock file)))
         (overrides (append overrides
                            (remove (match-lambda
                                      ((name . _) (assq name overrides)))
                                    (read-local-overrides directory)))))
    (cond ((pair? overrides)
           (let ((cached (string-append (cache-directory #:ensure? #f)
                                        "/flake-locks/"
                                        (overrides-key directory
                                                       overrides))))
             (if (and (file-exists? cached) (not update?))
                 (read-flake-lock cached)
                 (let ((lock (resolve-flake-lock
                              directory
                              #:previous committed
                              #:overrides overrides)))
                   (mkdir-p (dirname cached))
                   (write-flake-lock lock cached)
                   lock))))
          (committed committed)
          ((null? (flake-inputs
                   (read-flake (string-append directory "/flake.scm"))))
           (flake-lock))
          (else
           (raise (formatted-message
                   (G_ "'~a' has inputs and no guix.lock; run 'guix flake \
lock'")
                   directory))))))


;;;
;;; Using a lock.
;;;

(define (lock-node-location node directory)
  "Return where the repository of NODE is, for the lock of the flake in
DIRECTORY: its URL, or the absolute name of its directory."
  (case (lock-node-type node)
    ((git) (lock-node-url node))
    ((local) (absolute-path (lock-node-path node) directory))))

(define (lock-node-tree node directory)
  "Return the tree of NODE, a node of the lock of the flake in DIRECTORY, at
the recorded commit.  Nothing is looked up on the network when the cache has
that commit.  Raise an error if the files do not have the recorded hash."
  (let ((tree (case (lock-node-type node)
                ((git)
                 (fetch-git-tree (lock-node-url node)
                                 #:commit (lock-node-commit node)))
                ((local)
                 (fetch-local-tree
                  (absolute-path (lock-node-path node) directory)
                  #:commit (lock-node-commit node)
                  #:worktree? (lock-node-worktree? node))))))
    (unless (or (lock-node-worktree? node)
                (equal? (tree-hash tree) (lock-node-tree-hash node)))
      (raise (formatted-message
              (G_ "'~a': the files of commit ~a do not have the hash that \
the lock records")
              (lock-node-id node) (lock-node-commit node))))
    tree))

(define (lock-notices lock directory)
  "Return one line of text for each local input of LOCK, the lock of the
flake in DIRECTORY, whose checkout is not what the lock uses."
  (filter-map
   (lambda (node)
     (and (eq? 'local (lock-node-type node))
          (let ((path (absolute-path (lock-node-path node) directory)))
            (and (file-exists? path)
                 (let-values (((head changes?) (local-checkout-state path)))
                   (cond ((lock-node-worktree? node)
                          (and changes?
                               (format #f (G_ "~a: using the files of '~a' \
as they are, with changes that are not committed")
                                       (lock-node-id node) path)))
                         ((not (equal? head (lock-node-commit node)))
                          (format #f (G_ "~a: '~a' is at ~a; the lock uses \
~a")
                                  (lock-node-id node) path
                                  (string-take head 7)
                                  (string-take (lock-node-commit node) 7)))
                         (changes?
                          (format #f (G_ "~a: '~a' has changes that are not \
committed and not used")
                                  (lock-node-id node) path))
                         (else #f)))))))
   (flake-lock-nodes lock)))

(define (flake-metadata lock)
  "Return what 'guix flake metadata' shows of LOCK: for the flake and for
each node, its edges with the reason each points where it does."
  (define (edge->alist edge)
    `((name . ,(lock-edge-name edge))
      (node . ,(lock-edge-node edge))
      (kind . ,(lock-edge-kind edge))
      (as . ,(lock-edge-as edge))
      (target . ,(lock-edge-target edge))
      (options . ,(lock-edge-options edge))))

  `((inputs . ,(map edge->alist (flake-lock-inputs lock)))
    (nodes . ,(map (lambda (node)
                     `((id . ,(lock-node-id node))
                       (source . ,(lock-node-origin node))
                       (commit . ,(lock-node-commit node))
                       (tree-hash . ,(lock-node-tree-hash node))
                       (worktree? . ,(lock-node-worktree? node))
                       (authenticated? . ,(->bool
                                           (lock-node-authentication node)))
                       (inputs . ,(map edge->alist
                                       (lock-node-inputs node)))))
                   (flake-lock-nodes lock)))))

;;; resolve.scm ends here

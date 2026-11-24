;;; goonix: the flake lock: a graph of pinned trees.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (guix flakes lock)
  #:use-module ((guix flakes syntax) #:select (read-data-file))
  #:use-module (guix records)
  #:use-module (guix base32)
  #:use-module ((guix utils) #:select (with-atomic-file-output))
  #:use-module (ice-9 match)
  #:use-module (ice-9 pretty-print)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:export (flake-lock flake-lock? flake-lock-version
            flake-lock-inputs flake-lock-nodes

            lock-node lock-node? lock-node-id lock-node-type
            lock-node-url lock-node-path lock-node-branch lock-node-tag
            lock-node-commit lock-node-tree-hash lock-node-worktree?
            lock-node-authentication lock-node-inputs

            lock-edge lock-edge? lock-edge-name lock-edge-node
            lock-edge-kind lock-edge-as lock-edge-options lock-edge-target

            flake-lock-node flake-lock-root-edge lock-node-edge
            lock-node-origin

            sexp->flake-lock flake-lock->sexp flake-lock->string
            read-flake-lock write-flake-lock))

;;; Commentary:
;;;
;;; A lock is a graph.  A node is one tree: where it comes from, the commit,
;;; and the hash of its tracked files.  An edge is one input of a flake: the
;;; name the flake gives it, the node it stands for, what the flake uses it
;;; as, the options it sets on it, and why it points where it points
;;; (declared, followed, pinned, replaced, or taken from another lock).
;;;
;;; An input that follows another is an edge to the same node, so a followed
;;; tree is recorded once and named by reference.  The edges of the flake
;;; that owns the lock are the lock's own 'inputs'.
;;;
;;; Code:

(define-record-type* <flake-lock> flake-lock make-flake-lock
  flake-lock?
  (version flake-lock-version (default 1))
  (inputs  flake-lock-inputs (default '()))       ;list of <lock-edge>
  (nodes   flake-lock-nodes (default '())))       ;list of <lock-node>

(define-record-type* <lock-node> lock-node make-lock-node
  lock-node?
  (id             lock-node-id)                   ;string, unique in the lock
  (type           lock-node-type)                 ;'git | 'local
  (url            lock-node-url (default #f))
  (path           lock-node-path (default #f))
  (branch         lock-node-branch (default #f))
  (tag            lock-node-tag (default #f))
  (commit         lock-node-commit)               ;full hexadecimal ID
  ;; The NAR SHA-256 of the tracked files, in nix-base32; #f for a local
  ;; input used as a work tree, whose files are whatever they are.
  (tree-hash      lock-node-tree-hash (default #f))
  (worktree?      lock-node-worktree? (default #f))
  ;; #f, or ((commit COMMIT) (signer FINGERPRINT)) once the history from
  ;; that introduction to 'commit' has been authenticated.
  (authentication lock-node-authentication (default #f))
  (inputs         lock-node-inputs (default '()))) ;list of <lock-edge>

(define-record-type* <lock-edge> lock-edge make-lock-edge
  lock-edge?
  (name    lock-edge-name)                        ;symbol
  (node    lock-edge-node)                        ;node ID
  (kind    lock-edge-kind (default 'direct))
  (as      lock-edge-as (default 'flake))         ;'flake | 'library | 'source
  (options lock-edge-options (default '()))       ;alist of symbol and value
  ;; What a 'replaced' or 'same-as' edge was told, for 'guix flake metadata'.
  (target  lock-edge-target (default #f)))

(define %edge-kinds
  '(direct followed pinned replaced same-as))

(define (flake-lock-node lock id)
  "Return the node of LOCK whose ID is ID, or #f."
  (find (lambda (node) (string=? id (lock-node-id node)))
        (flake-lock-nodes lock)))

(define (flake-lock-root-edge lock name)
  "Return the edge of LOCK's own flake for its input NAME, or #f."
  (find (lambda (edge) (eq? name (lock-edge-name edge)))
        (flake-lock-inputs lock)))

(define (lock-node-edge node name)
  "Return the edge of NODE for its input NAME, or #f."
  (find (lambda (edge) (eq? name (lock-edge-name edge)))
        (lock-node-inputs node)))

(define (lock-node-origin node)
  "Return the repository NODE comes from, as a pair: its type and its URL or
path."
  (cons (lock-node-type node)
        (or (lock-node-url node) (lock-node-path node))))


;;;
;;; Reading.
;;;

(define (invalid datum message)
  (error (format #f "invalid flake lock: ~a: ~s" message datum)))

(define (fields datum allowed)
  "Check that DATUM is a list of (KEY VALUE ...) forms with keys among ALLOWED
and no key twice, and return it."
  (unless (list? datum)
    (invalid datum "expected a list of fields"))
  (let loop ((rest datum) (seen '()))
    (match rest
      (() datum)
      ((((? symbol? key) . (? list?)) . tail)
       (cond ((not (memq key allowed)) (invalid datum "unknown field"))
             ((memq key seen) (invalid datum "duplicate field"))
             (else (loop tail (cons key seen)))))
      (_ (invalid datum "expected (FIELD VALUE ...)")))))

(define (field properties key default)
  (match (assq key properties)
    (#f default)
    ((_ value) value)
    (_ (invalid properties "field takes one value"))))

(define (flag properties key)
  (match (assq key properties)
    (#f #f)
    ((_) #t)
    (_ (invalid properties "field takes no value"))))

(define (commit-id? string)
  (and (string? string)
       (memv (string-length string) '(40 64))
       (string-every char-set:hex-digit string)))

(define (tree-hash? string)
  (and (string? string)
       (let ((bytes (false-if-exception
                     (nix-base32-string->bytevector string))))
         (and bytes (= 32 (bytevector-length bytes))))))

(define (sexp->edge datum)
  (match datum
    (((? symbol? name) . properties)
     (fields properties '(node kind as options target))
     (let ((node    (field properties 'node #f))
           (kind    (field properties 'kind 'direct))
           (as      (field properties 'as 'flake))
           (options (match (assq 'options properties)
                      (#f '())
                      ((_ . options) options))))
       (unless (string? node) (invalid datum "edge without a node"))
       (unless (memq kind %edge-kinds) (invalid datum "unknown edge kind"))
       (unless (memq as '(flake library source))
         (invalid datum "unknown input kind"))
       (lock-edge
        (name name) (node node) (kind kind) (as as)
        (options (map (match-lambda
                        (((? symbol? option) value) (cons option value))
                        (_ (invalid datum "expected (OPTION VALUE)")))
                      options))
        (target (field properties 'target #f)))))
    (_ (invalid datum "expected (NAME (node ID) ...)"))))

(define (sexp->node datum)
  (match datum
    (((? string? id) . properties)
     (fields properties '(git local branch tag commit tree worktree
                          authentication inputs))
     (let ((git    (field properties 'git #f))
           (local  (field properties 'local #f))
           (commit (field properties 'commit #f))
           (worktree? (flag properties 'worktree))
           (tree   (match (field properties 'tree #f)
                     (#f #f)
                     (('nar-sha256 hash) hash)
                     (_ (invalid datum "unknown tree hash format"))))
           (authentication
            (match (assq 'authentication properties)
              (#f #f)
              ((_ ('commit (? commit-id? commit)) ('signer (? string? signer)))
               `((commit ,commit) (signer ,signer)))
              (_ (invalid datum "invalid authentication")))))
       (unless (or (and (string? git) (not local))
                   (and (string? local) (not git)))
         (invalid datum "node needs one of (git URL) and (local PATH)"))
       (unless (commit-id? commit)
         (invalid datum "commit must be a full hexadecimal commit ID"))
       (if worktree?
           (when (or tree git)
             (invalid datum "only a local node without a tree hash can be \
a work tree"))
           (unless (tree-hash? tree)
             (invalid datum "tree must be (nar-sha256 NIX-BASE32)")))
       (lock-node
        (id id)
        (type (if git 'git 'local))
        (url git) (path local)
        (branch (field properties 'branch #f))
        (tag (field properties 'tag #f))
        (commit commit) (tree-hash tree) (worktree? worktree?)
        (authentication authentication)
        (inputs (match (assq 'inputs properties)
                  (#f '())
                  ((_ . edges) (map sexp->edge edges)))))))
    (_ (invalid datum "expected (ID (git URL) ...)"))))

(define (check-graph lock)
  "Check that node IDs are unique in LOCK, that no input name occurs twice in
one flake and that every edge leads to a node; return LOCK."
  (define ids
    (map lock-node-id (flake-lock-nodes lock)))

  (define (check-edges edges where)
    (let loop ((edges edges) (seen '()))
      (match edges
        (() #t)
        ((edge . rest)
         (when (memq (lock-edge-name edge) seen)
           (invalid (lock-edge-name edge)
                    (format #f "input named twice in ~a" where)))
         (unless (member (lock-edge-node edge) ids)
           (invalid (lock-edge-node edge)
                    (format #f "edge '~a' of ~a leads to no node"
                            (lock-edge-name edge) where)))
         (loop rest (cons (lock-edge-name edge) seen))))))

  (unless (= (length ids) (length (delete-duplicates ids)))
    (invalid ids "node ID used twice"))
  (check-edges (flake-lock-inputs lock) "the flake")
  (for-each (lambda (node)
              (check-edges (lock-node-inputs node) (lock-node-id node)))
            (flake-lock-nodes lock))
  lock)

(define (sexp->flake-lock datum)
  "Return the lock that DATUM, an S-expression, denotes.  Raise an error if
DATUM is not a well-formed lock."
  (match datum
    (('flake-lock . properties)
     (fields properties '(version inputs nodes))
     (unless (eqv? 1 (field properties 'version #f))
       (invalid datum "unsupported lock version"))
     (check-graph
      (flake-lock
       (inputs (match (assq 'inputs properties)
                 (#f '())
                 ((_ . edges) (map sexp->edge edges))))
       (nodes (match (assq 'nodes properties)
                (#f '())
                ((_ . nodes) (map sexp->node nodes)))))))
    (_ (invalid datum "expected (flake-lock (version 1) ...)"))))

(define (read-flake-lock file)
  "Read the lock in FILE.  The file is data: nothing in it is evaluated."
  (sexp->flake-lock (read-data-file file)))


;;;
;;; Writing.
;;;

(define (edge->sexp edge)
  `(,(lock-edge-name edge)
    (node ,(lock-edge-node edge))
    ,@(if (eq? 'direct (lock-edge-kind edge))
          '()
          `((kind ,(lock-edge-kind edge))))
    ,@(if (lock-edge-target edge)
          `((target ,(lock-edge-target edge)))
          '())
    ,@(if (eq? 'flake (lock-edge-as edge))
          '()
          `((as ,(lock-edge-as edge))))
    ,@(match (lock-edge-options edge)
        (() '())
        (options `((options ,@(map (match-lambda
                                     ((option . value) (list option value)))
                                   options)))))))

(define (node->sexp node)
  `(,(lock-node-id node)
    ,(if (eq? 'git (lock-node-type node))
         `(git ,(lock-node-url node))
         `(local ,(lock-node-path node)))
    ,@(if (lock-node-branch node) `((branch ,(lock-node-branch node))) '())
    ,@(if (lock-node-tag node) `((tag ,(lock-node-tag node))) '())
    (commit ,(lock-node-commit node))
    ,@(if (lock-node-worktree? node)
          '((worktree))
          `((tree (nar-sha256 ,(lock-node-tree-hash node)))))
    ,@(match (lock-node-authentication node)
        (#f '())
        (authentication `((authentication ,@authentication))))
    ,@(match (lock-node-inputs node)
        (() '())
        (edges `((inputs ,@(map edge->sexp edges)))))))

(define (flake-lock->sexp lock)
  "Return LOCK as an S-expression.  Equal locks give equal S-expressions."
  `(flake-lock
    (version ,(flake-lock-version lock))
    (inputs ,@(map edge->sexp (flake-lock-inputs lock)))
    (nodes ,@(map node->sexp (flake-lock-nodes lock)))))

(define (flake-lock->string lock)
  "Return the text of the file that holds LOCK."
  (call-with-output-string
    (lambda (port)
      (display ";; goonix: generated by 'guix flake lock'; do not edit.\n"
               port)
      (pretty-print (flake-lock->sexp lock) port #:max-expr-width 78))))

(define (write-flake-lock lock file)
  "Write LOCK to FILE, replacing it in one step, and return FILE."
  (with-atomic-file-output file
    (lambda (port)
      (display (flake-lock->string lock) port)))
  file)

;;; lock.scm ends here

;;; goonix: the trees of flake inputs.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (guix flakes checkout)
  #:use-module (guix base32)
  #:use-module (guix diagnostics)
  #:use-module (guix i18n)
  #:use-module (guix git)
  #:use-module ((guix hash) #:select (file-hash*))
  #:use-module ((guix openpgp) #:select (openpgp-fingerprint->bytevector))
  #:use-module ((guix pure-eval) #:select (git-top-level
                                           tracked-file-predicate
                                           tracked-tree-revision))
  #:use-module ((guix flakes syntax) #:select (read-data-file))
  #:use-module (guix records)
  #:use-module (guix store)
  #:autoload   (git oid) (string->oid)
  #:autoload   (guix git-authenticate) (authenticate-repository)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-34)
  #:export (tree tree? tree-directory tree-select? tree-commit tree-hash
            tree-worktree? tree-repository

            fetch-git-tree fetch-local-tree
            regular-file tree-file import-tree authenticate-tree
            local-checkout-state))

;;; Commentary:
;;;
;;; A tree is the set of tracked files of one input at one commit, somewhere
;;; on disk, with the hash that names it.
;;;
;;; A Git input lives in the cache that 'guix pull' uses, one checkout per
;;; URL.  That checkout is shared and moves with every fetch, so a tree is
;;; good only until the next fetch of its URL: whoever fetches reads what it
;;; needs at once, and whoever imports checks the result against the hash.
;;; A local input that is not a work tree goes through the same cache, so
;;; that what is used is the commit and not the state of the directory.
;;;
;;; Code:

(define-record-type* <tree> tree make-tree
  tree?
  (directory  tree-directory)             ;where the files are
  (select?    tree-select?)               ;which of them belong to the tree
  (commit     tree-commit)                ;full commit ID
  ;; NAR SHA-256 in nix-base32, or #f for a work tree.
  (hash       tree-hash (default #f))
  (worktree?  tree-worktree? (default #f))
  ;; The repository that has the history, for authentication.
  (repository tree-repository (default #f)))

(define (not-dot-git? file stat)
  (not (string=? ".git" (basename file))))

(define (nar-hash directory select?)
  (bytevector->nix-base32-string
   (file-hash* directory #:recursive? #t #:select? select?)))

(define* (fetch-git-tree url #:key branch tag commit (subdirectory ""))
  "Bring the cached checkout of URL to COMMIT, else to TAG, else to BRANCH,
else to the default branch of the remote, and return the tree found there, or
below SUBDIRECTORY of it.  A reference that is a commit ID is not looked up
on the network when the cache has it."
  (let-values (((checkout commit relation)
                (update-cached-checkout url
                                        #:ref (cond (commit `(commit . ,commit))
                                                    (tag `(tag . ,tag))
                                                    (branch `(branch . ,branch))
                                                    (else '())))))
    (let ((directory (if (string-null? subdirectory)
                         checkout
                         (string-append checkout "/" subdirectory))))
      (unless (file-exists? directory)
        (raise (formatted-message
                (G_ "commit ~a of '~a' has no directory '~a'")
                commit url subdirectory)))
      (tree (directory directory)
            (select? not-dot-git?)
            (commit commit)
            (hash (nar-hash directory not-dot-git?))
            (repository checkout)))))

(define* (fetch-local-tree path #:key commit worktree?)
  "Return the tree of the checkout at PATH: its tracked files as they are
when WORKTREE?, and otherwise those of COMMIT, or of the commit that is
checked out.  PATH may be a directory inside a checkout."
  (let* ((path (canonicalize-path path))
         (top  (or (git-top-level path)
                   (raise (formatted-message
                           (G_ "local input '~a' is not in a Git checkout")
                           path)))))
    (let-values (((_ head reference) (repository-info top)))
      (unless head
        (raise (formatted-message
                (G_ "the checkout '~a' has no commit yet") top)))
      (if worktree?
          (tree (directory path)
                (select? (tracked-file-predicate path))
                (commit head)
                (worktree? #t)
                (repository top))
          (fetch-git-tree top
                          #:commit (or commit head)
                          #:subdirectory
                          (if (string=? path top)
                              ""
                              (string-drop path
                                           (+ 1 (string-length top)))))))))

(define (regular-file directory name)
  "Return the name of the regular file NAME of DIRECTORY, or #f if there is
none.  Raise an error if NAME is a symbolic link: the host reads these files,
and a link could lead it anywhere."
  (let* ((file (string-append directory "/" name))
         (stat (false-if-exception (lstat file))))
    (match (and stat (stat:type stat))
      ('regular file)
      ('symlink
       (raise (formatted-message
               (G_ "'~a' is a symbolic link; it must be a file") file)))
      (_ #f))))

(define (tree-file tree name)
  "Return the name of the regular file NAME of TREE, or #f if TREE has no
such file.  Raise an error if it is a symbolic link."
  (let ((file (regular-file (tree-directory tree) name)))
    (and file
         ((tree-select? tree) file (lstat file))
         file)))

(define* (import-tree store tree #:optional (name "flake-input"))
  "Add the files of TREE to STORE and return the store item.  When TREE has a
hash, the item is the one the hash names; a checkout that no longer holds
what was hashed is refused."
  (let* ((name (string-append name "-" (string-take (tree-commit tree) 7)))
         (item (add-to-store store name #t "sha256" (tree-directory tree)
                             #:select? (tree-select? tree))))
    (when (and (tree-hash tree)
               (not (string=? item
                              (fixed-output-path
                               name
                               (nix-base32-string->bytevector
                                (tree-hash tree))
                               #:recursive? #t))))
      (raise (formatted-message
              (G_ "the files of '~a' are not those of the recorded tree ~a")
              (tree-directory tree) (tree-hash tree))))
    item))

(define (keyring-reference tree)
  "Return the name of the branch that holds the OpenPGP keys of TREE's
repository: the one its '.guix-channel' names, as for a channel, or
\"keyring\"."
  (or (and=> (tree-file tree ".guix-channel")
             (lambda (file)
               (match (read-data-file file)
                 (('channel . properties)
                  (match (assq 'keyring-reference properties)
                    ((_ (? string? reference)) reference)
                    (_ #f)))
                 (_ #f))))
      "keyring"))

(define (authenticate-tree tree introduction)
  "Authenticate the history of TREE's repository from INTRODUCTION, a list
((commit COMMIT) (signer FINGERPRINT)), to the commit of TREE, the way
channels are authenticated.  Raise an error if that fails."
  (match introduction
    ((('commit start) ('signer signer))
     (let ((reference (string-append
                       ;; In the cache the branches are the remote's.
                       (if (tree-worktree? tree) "" "origin/")
                       (keyring-reference tree))))
       (with-repository (tree-repository tree) repository
         (authenticate-repository repository
                                  (string->oid start)
                                  (openpgp-fingerprint->bytevector signer)
                                  #:end (string->oid (tree-commit tree))
                                  #:keyring-reference reference
                                  ;; What was authenticated for one signer
                                  ;; says nothing about another.
                                  #:cache-key
                                  (string-append "flakes/" start "-"
                                                 (string-delete #\space
                                                                signer))))))))

(define (local-checkout-state path)
  "Return two values for the checkout at PATH: the commit that is checked
out, and whether tracked files have changes that are not committed."
  (let ((top (git-top-level (canonicalize-path path))))
    (let-values (((_ head reference) (repository-info top)))
      (values head (not (tracked-tree-revision top))))))

;;; checkout.scm ends here

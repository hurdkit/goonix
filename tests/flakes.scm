;;; goonix: tests for flake declarations, locks and their resolution.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (test-flakes)
  #:use-module (guix flakes syntax)
  #:use-module (guix flakes lock)
  #:use-module (guix flakes checkout)
  #:use-module (guix flakes resolve)
  #:use-module ((guix git) #:select (%repository-cache-directory))
  #:use-module (guix store)
  #:use-module (guix tests)
  #:use-module (guix tests git)
  #:use-module (guix tests gnupg)
  #:use-module ((guix utils) #:select (call-with-temporary-directory))
  #:use-module ((guix build utils)
                #:select (mkdir-p which with-directory-excursion))
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-34)
  #:use-module (srfi srfi-64))

(test-begin "flakes")

(define %store (open-connection-for-tests))

(define (contents file)
  (call-with-input-file file get-string-all))

(define (write-file file text)
  (mkdir-p (dirname file))
  (call-with-output-file file
    (lambda (port) (display text port))))

(define (git directory . arguments)
  "Run Git in DIRECTORY and return its trimmed output."
  (let* ((pipe (apply open-pipe* OPEN_READ (git-command) "-C" directory
                      arguments))
         (output (string-trim-right (get-string-all pipe))))
    (unless (zero? (close-pipe pipe))
      (error "git failed" arguments))
    output))

(define (head directory)
  (git directory "rev-parse" "HEAD"))

(define (populate-git-repository directory directives)
  ;; Apply DIRECTIVES to the repository in DIRECTORY, made if need be.
  (with-git-repository directory directives directory))

(define (commit! directory . files)
  "Add FILES, pairs of a name and a text, to the repository in DIRECTORY,
which is made if need be; commit, and return the commit."
  (populate-git-repository
   directory
   `(,@(map (match-lambda
              ((name . text) `(add ,name ,text)))
            files)
     (commit "a commit")))
  (head directory))

(define (flake . inputs)
  "Return the text of a flake.scm with INPUTS.  Its outputs must not run."
  (format #f "(flake (format 1) (inputs ~{~s~^ ~})~%  \
(outputs (lambda (in) (error \"the outputs ran\"))))~%"
          inputs))

(define (call-with-workspace proc)
  "Call PROC with a new directory.  Git checkouts are cached below it."
  (call-with-temporary-directory
   (lambda (directory)
     (parameterize ((%repository-cache-directory
                     (string-append directory "/cache")))
       (proc directory)))))

(define-syntax-rule (with-workspace directory body ...)
  (call-with-workspace (lambda (directory) body ...)))

(define-syntax-rule (raises? body ...)
  ;; Whether BODY raises, whatever it raises.
  (guard (condition (#t #t))
    body ...
    #f))

(define (node-of lock . names)
  "Return the node that the path NAMES of input names leads to in LOCK."
  (let loop ((edge (flake-lock-root-edge lock (first names)))
             (names (cdr names)))
    (let ((node (flake-lock-node lock (lock-edge-node edge))))
      (match names
        (() node)
        ((name . rest) (loop (lock-node-edge node name) rest))))))

(define (edge-of lock . names)
  "Return the last edge on the path NAMES of input names in LOCK."
  (match (reverse names)
    ((name) (flake-lock-root-edge lock name))
    ((name . parents)
     (lock-node-edge (apply node-of lock (reverse parents)) name))))


;;;
;;; Reading.
;;;

(test-assert "flake.scm is read as data"
  (with-workspace directory
    (let ((file (string-append directory "/flake.scm")))
      (write-file file "(flake (format 1) (description \"safe\")
 (modules \"guix\")
 (inputs (dep (git \"https://example.org/dep\") (branch \"main\")
              (as source) (options (debug? #t) (level 3)))
         (other (local \"../other\") (worktree)
                (inputs (theirs follows dep) (more (git \"x\")))))
 (options (debug? boolean #f \"Debug output\"))
 (outputs (lambda (in) (error \"the outputs ran\"))))")
      (let ((flake (read-flake file)))
        (match (flake-inputs flake)
          ((dep other)
           (and (string=? "safe" (flake-description flake))
                (string=? "guix" (flake-modules flake))
                (eq? 'git (flake-input-type dep))
                (eq? 'source (flake-input-as dep))
                (equal? '((debug? . #t) (level . 3))
                        (flake-input-options dep))
                ;; What an input is used as is left open unless it says.
                (not (flake-input-as other))
                (flake-input-worktree? other)
                (equal? '((theirs . dep)) (flake-input-follows other))
                (equal? '((more (git "x"))) (flake-input-overrides other))
                (equal? '(debug?)
                        (map flake-option-name (flake-options flake)))
                (pair? (flake-outputs-expression flake)))))))))

(test-assert "a reader extension in flake.scm is refused, not run"
  ;; The code after #. leaves a file behind if the reader runs it; that the
  ;; read fails is not enough, since running the code would fail it too.
  (with-workspace directory
    (let ((file  (string-append directory "/flake.scm"))
          (trace (string-append directory "/executed")))
      (write-file file
                  (format #f "(flake (format 1) (description #.(begin \
(call-with-output-file ~s (lambda (port) (display 1 port))) \"x\")))"
                          trace))
      (and (raises? (read-flake file))
           (not (file-exists? trace))))))

(define %commit (make-string 40 #\a))
(define %hash "0000000000000000000000000000000000000000000000000000")

(define %lock-sexp
  `(flake-lock
    (version 1)
    (inputs (guix (node "guix") (as library))
            (dep (node "dep") (options (debug? #t)))
            (tree (node "tree") (kind replaced) (target (local "../tree"))
                  (as source)))
    (nodes ("guix" (git "https://example.org/guix") (branch "main")
            (commit ,%commit) (tree (nar-sha256 ,%hash)))
           ("dep" (git "https://example.org/dep") (tag "v1")
            (commit ,%commit) (tree (nar-sha256 ,%hash))
            (authentication (commit ,%commit) (signer "AAAA BBBB"))
            (inputs (guix (node "guix") (kind followed) (as library))
                    (dep (node "dep"))))
           ("tree" (local "../tree") (commit ,%commit) (worktree)))))

(test-equal "a lock is read and written back unchanged"
  %lock-sexp
  (flake-lock->sexp (sexp->flake-lock %lock-sexp)))

(test-assert "a lock on disk reads back as the same lock"
  (with-workspace directory
    (let ((file (string-append directory "/guix.lock"))
          (lock (sexp->flake-lock %lock-sexp)))
      (write-flake-lock lock file)
      (let ((text (contents file)))
        (write-flake-lock (read-flake-lock file) file)
        (and (string=? text (contents file))
             (equal? %lock-sexp
                     (flake-lock->sexp (read-flake-lock file))))))))

(test-assert "an input is found by its edge, not by its name"
  ;; 'dep' has an input called 'dep' as well: itself.
  (let ((lock (sexp->flake-lock %lock-sexp)))
    (and (string=? "dep" (lock-node-id (node-of lock 'dep)))
         (string=? "guix" (lock-node-id (node-of lock 'dep 'guix)))
         (eq? 'followed (lock-edge-kind (edge-of lock 'dep 'guix)))
         (equal? '((debug? . #t)) (lock-edge-options (edge-of lock 'dep)))
         (not (flake-lock-root-edge lock 'absent)))))

(define (malformed? . replacement)
  ;; Whether %LOCK-SEXP is refused once REPLACEMENT is done on its text.
  (match replacement
    ((from to)
     (let* ((text (object->string %lock-sexp))
            (at   (string-contains text from)))
       (unless at (error "the test does not change the lock" from))
       (raises?
        (sexp->flake-lock
         (call-with-input-string
             (string-append (string-take text at) to
                            (string-drop text (+ at (string-length from))))
           read)))))))

(test-assert "malformed locks are refused"
  (and (malformed? "(version 1)" "(version 2)")
       (malformed? "(branch \"main\")" "(bogus \"main\")")
       (malformed? "(node \"tree\")" "(node \"absent\")")
       (malformed? "(kind followed)" "(kind borrowed)")
       (malformed? "(as source)" "(as binary)")
       (malformed? "(tree (nar-sha256" "(tree (md5")
       (malformed? "(\"tree\" (local" "(\"dep\" (local")
       (malformed? "(dep (node \"dep\"))" "(guix (node \"dep\"))")
       (malformed? (string-append "(commit \"" %commit "\") (worktree)")
                   "(commit \"abc\") (worktree)")
       (malformed? (string-append "(nar-sha256 \"" %hash "\")")
                   "(nar-sha256 \"zz\")")))


;;;
;;; Trees.
;;;

(test-assert "a git tree is its tracked files at the commit"
  (with-workspace directory
    (let* ((repository (string-append directory "/dep"))
           (commit (commit! repository '("file" . "one") '("sub/file" . "x")))
           (tree   (fetch-git-tree repository)))
      (and (string=? commit (tree-commit tree))
           (tree-file tree "sub/file")
           (not (tree-file tree ".git"))
           (not (tree-file tree "absent"))
           (let ((item (import-tree %store tree)))
             (and (string=? "one" (contents (string-append item "/file")))
                  (not (file-exists? (string-append item "/.git")))))))))

(test-assert "an import that does not match the hash is refused"
  (with-workspace directory
    (let* ((repository (string-append directory "/dep"))
           (_    (commit! repository '("file" . "one")))
           (tree (fetch-git-tree repository)))
      ;; Change the checkout behind the tree's back.
      (write-file (string-append (tree-directory tree) "/file") "two")
      (raises? (import-tree %store tree)))))

(test-equal "a local tree is the commit, whatever the directory holds"
  '("committed" #f)
  (with-workspace directory
    (let ((repository (string-append directory "/dep")))
      (commit! repository '("file" . "committed"))
      (write-file (string-append repository "/file") "changed")
      (write-file (string-append repository "/untracked") "new")
      (let ((item (import-tree %store (fetch-local-tree repository))))
        (list (contents (string-append item "/file"))
              (file-exists? (string-append item "/untracked")))))))

(test-equal "a work tree is the tracked files as they are"
  '("changed" "staged" #f)
  (with-workspace directory
    (let ((repository (string-append directory "/dep")))
      (commit! repository '("file" . "committed"))
      (write-file (string-append repository "/file") "changed")
      (write-file (string-append repository "/added") "staged")
      (git repository "add" "added")
      (write-file (string-append repository "/untracked") "new")
      (let ((item (import-tree %store
                               (fetch-local-tree repository
                                                 #:worktree? #t))))
        (list (contents (string-append item "/file"))
              (contents (string-append item "/added"))
              (file-exists? (string-append item "/untracked")))))))


;;;
;;; Resolution.
;;;

(define (project! directory . inputs)
  "Make DIRECTORY a flake with INPUTS, not committed, and return DIRECTORY."
  (write-file (string-append directory "/flake.scm") (apply flake inputs))
  directory)

(test-assert "locking records the commit and the hash, and runs nothing"
  (with-workspace directory
    (let* ((dep     (string-append directory "/dep"))
           (commit  (commit! dep `("flake.scm" . ,(flake))))
           (project (project! (string-append directory "/project")
                              `(dep (git ,dep))))
           (lock    (lock-flake project))
           (node    (node-of lock 'dep)))
      (and (file-exists? (string-append project "/guix.lock"))
           (string=? commit (lock-node-commit node))
           (string=? (tree-hash (fetch-git-tree dep))
                     (lock-node-tree-hash node))
           (eq? 'flake (lock-edge-as (edge-of lock 'dep)))
           (eq? 'direct (lock-edge-kind (edge-of lock 'dep)))))))

(test-assert "locking twice changes nothing, even after the branch moved"
  (with-workspace directory
    (let* ((dep     (string-append directory "/dep"))
           (first   (commit! dep `("flake.scm" . ,(flake))))
           (project (project! (string-append directory "/project")
                              `(dep (git ,dep) (branch "master"))))
           (file    (string-append project "/guix.lock")))
      (lock-flake project)
      (let ((text (contents file)))
        (commit! dep '("new" . "file"))
        (lock-flake project)
        (and (string=? text (contents file))
             (string=? first
                       (lock-node-commit
                        (node-of (read-flake-lock file) 'dep))))))))

(test-assert "updating an input moves it, and only it"
  (with-workspace directory
    (let* ((one     (string-append directory "/one"))
           (two     (string-append directory "/two"))
           (one-1   (commit! one `("flake.scm" . ,(flake))))
           (two-1   (commit! two `("flake.scm" . ,(flake))))
           (project (project! (string-append directory "/project")
                              `(one (git ,one)) `(two (git ,two)))))
      (lock-flake project)
      (let ((one-2 (commit! one '("new" . "file")))
            (two-2 (commit! two '("new" . "file"))))
        (let ((lock (lock-flake project #:update '(one))))
          (and (not (string=? one-1 one-2))
               (string=? one-2 (lock-node-commit (node-of lock 'one)))
               (string=? two-1 (lock-node-commit (node-of lock 'two)))
               (let ((lock (lock-flake project #:update #t)))
                 (string=? two-2 (lock-node-commit (node-of lock 'two))))
               ;; An unknown name is an error, not a silent no-op.
               (raises? (lock-flake project #:update '(three)))))))))

(test-assert "a lock whose hash does not fit the commit is refused"
  (with-workspace directory
    (let* ((dep     (string-append directory "/dep"))
           (_       (commit! dep `("flake.scm" . ,(flake))))
           (project (project! (string-append directory "/project")
                              `(dep (git ,dep))))
           (file    (string-append project "/guix.lock"))
           (lock    (lock-flake project))
           (hash    (lock-node-tree-hash (node-of lock 'dep)))
           (text    (contents file))
           (at      (string-contains text hash)))
      ;; The control: the lock as written is accepted.
      (lock-node-tree (node-of lock 'dep) project)
      (write-file file
                  (string-append (string-take text at) %hash
                                 (string-drop text
                                              (+ at (string-length hash)))))
      (and (raises? (lock-node-tree (node-of (read-flake-lock file) 'dep)
                                    project))
           (raises? (lock-flake project))))))

(test-assert "two repositories are resolved independently"
  (with-workspace directory
    (let* ((one     (string-append directory "/one"))
           (two     (string-append directory "/two"))
           (one-1   (commit! one `("flake.scm" . ,(flake)) '("is" . "one")))
           (two-1   (commit! two `("flake.scm" . ,(flake)) '("is" . "two")))
           (project (project! (string-append directory "/project")
                              `(one (git ,one)) `(two (git ,two))))
           (lock    (lock-flake project)))
      (and (not (string=? one-1 two-1))
           (string=? one-1 (lock-node-commit (node-of lock 'one)))
           (string=? two-1 (lock-node-commit (node-of lock 'two)))
           (string=? "two"
                     (contents
                      (string-append
                       (import-tree %store
                                    (lock-node-tree (node-of lock 'two)
                                                    project))
                       "/is")))))))

(test-assert "what an input is used as follows from its tree"
  (with-workspace directory
    (let* ((with-flake (string-append directory "/flake"))
           (channel    (string-append directory "/channel"))
           (plain      (string-append directory "/plain")))
      (commit! with-flake `("flake.scm" . ,(flake)))
      (commit! channel '(".guix-channel" . "(channel (version 0))"))
      (commit! plain '("data" . "x"))
      (let ((lock (lock-flake
                   (project! (string-append directory "/project")
                             `(a (git ,with-flake))
                             `(b (git ,channel))
                             `(c (git ,plain) (as source))
                             `(d (git ,with-flake) (as source))))))
        (and (equal? '(flake library source source)
                     (map lock-edge-as (flake-lock-inputs lock)))
             ;; Nothing says what a plain tree is for.
             (raises? (lock-flake
                       (project! (string-append directory "/project-2")
                                 `(c (git ,plain)))))
             ;; A tree without flake.scm is not a flake.
             (raises? (lock-flake
                       (project! (string-append directory "/project-3")
                                 `(c (git ,plain) (as flake))))))))))

(test-assert "an input's input of the same repository follows the flake's"
  ;; 'middle' calls the shared repository 'lib'; the flake calls it
  ;; 'shared'.  The repository decides, not the name, and there is one node.
  (with-workspace directory
    (let* ((shared  (string-append directory "/shared"))
           (middle  (string-append directory "/middle"))
           (old     (commit! shared `("flake.scm" . ,(flake))))
           (_       (commit! middle
                             `("flake.scm"
                               . ,(flake `(lib (git ,shared)
                                               (commit ,old))))))
           (new     (commit! shared '("new" . "file")))
           (project (project! (string-append directory "/project")
                              `(shared (git ,shared))
                              `(middle (git ,middle))))
           (lock    (lock-flake project)))
      (and (not (string=? old new))
           (eq? 'followed (lock-edge-kind (edge-of lock 'middle 'lib)))
           (string=? (lock-node-id (node-of lock 'shared))
                     (lock-node-id (node-of lock 'middle 'lib)))
           (string=? new (lock-node-commit (node-of lock 'middle 'lib)))
           (= 2 (length (flake-lock-nodes lock)))))))

(test-assert "'follows' joins inputs of different repositories"
  (with-workspace directory
    (let* ((ours    (string-append directory "/ours"))
           (theirs  (string-append directory "/theirs"))
           (middle  (string-append directory "/middle"))
           (_       (commit! ours `("flake.scm" . ,(flake))))
           (_       (commit! theirs `("flake.scm" . ,(flake))))
           (_       (commit! middle
                             `("flake.scm"
                               . ,(flake `(theirs (git ,theirs))))))
           (project (string-append directory "/project"))
           (lock    (lock-flake
                     (project! project
                               `(ours (git ,ours))
                               `(middle (git ,middle)
                                        (inputs (theirs follows ours)))))))
      (and (eq? 'followed (lock-edge-kind (edge-of lock 'middle 'theirs)))
           (eq? 'ours (lock-edge-target (edge-of lock 'middle 'theirs)))
           (string=? (lock-node-id (node-of lock 'ours))
                     (lock-node-id (node-of lock 'middle 'theirs)))
           ;; The repository of 'theirs' is not in the lock at all.
           (= 2 (length (flake-lock-nodes lock)))
           ;; Both names must exist.
           (raises? (lock-flake
                     (project! project
                               `(ours (git ,ours))
                               `(middle (git ,middle)
                                        (inputs (absent follows ours))))))
           (raises? (lock-flake
                     (project! project
                               `(ours (git ,ours))
                               `(middle (git ,middle)
                                        (inputs (theirs follows absent))))))))))

(test-assert "an input's input can be replaced"
  (with-workspace directory
    (let* ((theirs  (string-append directory "/theirs"))
           (other   (string-append directory "/other"))
           (middle  (string-append directory "/middle"))
           (_       (commit! theirs `("flake.scm" . ,(flake))))
           (commit  (commit! other `("flake.scm" . ,(flake)) '("is" . "o")))
           (_       (commit! middle
                             `("flake.scm"
                               . ,(flake `(theirs (git ,theirs))))))
           (lock    (lock-flake
                     (project! (string-append directory "/project")
                               `(middle (git ,middle)
                                        (inputs (theirs (git ,other))))))))
      (and (eq? 'replaced (lock-edge-kind (edge-of lock 'middle 'theirs)))
           (equal? `((git ,other))
                   (lock-edge-target (edge-of lock 'middle 'theirs)))
           (string=? commit
                     (lock-node-commit (node-of lock 'middle 'theirs)))))))

(test-assert "a pinned input keeps the commits of its own lock"
  ;; Two inputs, each with a lock that pins another commit of 'child'; the
  ;; flake has 'child' itself, at a third.
  (with-workspace directory
    (let* ((child  (string-append directory "/child"))
           (left   (string-append directory "/left"))
           (right  (string-append directory "/right"))
           (parent (lambda (directory)
                     (project! directory `(child (git ,child)))
                     (lock-flake directory)
                     (commit! directory
                              `("flake.scm"
                                . ,(contents
                                    (string-append directory "/flake.scm")))
                              `("guix.lock"
                                . ,(contents
                                    (string-append directory
                                                   "/guix.lock"))))))
           (first  (commit! child `("flake.scm" . ,(flake))))
           (_      (parent left))
           (second (commit! child '("second" . "x")))
           (_      (parent right))
           (third  (commit! child '("third" . "x")))
           (lock   (lock-flake
                    (project! (string-append directory "/project")
                              `(child (git ,child))
                              `(left (git ,left) (pinned))
                              `(right (git ,right) (pinned))))))
      (and (= 3 (length (delete-duplicates (list first second third))))
           (string=? third (lock-node-commit (node-of lock 'child)))
           (string=? first (lock-node-commit (node-of lock 'left 'child)))
           (string=? second (lock-node-commit (node-of lock 'right 'child)))
           (eq? 'pinned (lock-edge-kind (edge-of lock 'left 'child)))
           ;; Without (pinned), both follow the flake's.
           (let ((lock (lock-flake
                        (project! (string-append directory "/project-2")
                                  `(child (git ,child))
                                  `(left (git ,left))))))
             (string=? third
                       (lock-node-commit (node-of lock 'left 'child))))))))

(test-assert "inputs that depend on each other are resolved once each"
  ;; 'a' needs 'b' and 'b' needs 'a'.  With (pinned) nothing follows the
  ;; flake, so only the check for a tree already on the way ends this.
  (with-workspace directory
    (let* ((a (string-append directory "/a"))
           (b (string-append directory "/b")))
      (commit! a `("flake.scm" . ,(flake `(b (git ,b)))))
      (commit! b `("flake.scm" . ,(flake `(a (git ,a)))))
      (let ((lock (lock-flake
                   (project! (string-append directory "/project")
                             `(a (git ,a) (pinned))))))
        (and (= 2 (length (flake-lock-nodes lock)))
             (string=? (lock-node-id (node-of lock 'a))
                       (lock-node-id (node-of lock 'a 'b 'a))))))))

(test-assert "'same-as' takes the commit that another lock has"
  (with-workspace directory
    (let* ((shared  (string-append directory "/shared"))
           (other   (string-append directory "/other"))
           (pinned  (commit! shared `("flake.scm" . ,(flake))))
           (_       (lock-flake (project! other `(shared (git ,shared)))))
           (moved   (commit! shared '("new" . "file")))
           (lock    (lock-flake
                     (project! (string-append directory "/project")
                               '(mine (same-as "../other" shared))))))
      (and (not (string=? pinned moved))
           (string=? pinned (lock-node-commit (node-of lock 'mine)))
           (eq? 'same-as (lock-edge-kind (edge-of lock 'mine)))))))

(test-assert "the dependencies of a channel are locked as libraries"
  (with-workspace directory
    (let* ((base    (string-append directory "/base"))
           (channel (string-append directory "/channel"))
           (commit  (commit! base '(".guix-channel" . "(channel (version 0))")))
           (_       (commit! channel
                             `(".guix-channel"
                               . ,(object->string
                                   `(channel
                                     (version 0)
                                     (dependencies
                                      (channel (name base) (url ,base))))))))
           (lock    (lock-flake
                     (project! (string-append directory "/project")
                               `(channel (git ,channel))))))
      (and (eq? 'library (lock-edge-as (edge-of lock 'channel)))
           (eq? 'library (lock-edge-as (edge-of lock 'channel 'base)))
           (string=? commit
                     (lock-node-commit (node-of lock 'channel 'base)))))))

(test-equal "options set on an input are recorded on its edge"
  '((debug? . #t) (name . "x"))
  (with-workspace directory
    (let ((dep (string-append directory "/dep")))
      (commit! dep `("flake.scm" . ,(flake)))
      (lock-edge-options
       (edge-of (lock-flake
                 (project! (string-append directory "/project")
                           `(dep (git ,dep)
                                 (options (debug? #t) (name "x")))))
                'dep)))))


(test-assert "a flake from a repository cannot name a local path"
  (with-workspace directory
    (let* ((secret (string-append directory "/secret"))
           (dep    (string-append directory "/dep"))
           (_      (commit! secret `("flake.scm" . ,(flake))))
           (_      (commit! dep
                            `("flake.scm"
                              . ,(flake `(secret (local ,secret))))))
           (lock   (lambda (name . inputs)
                     (lock-flake
                      (apply project! (string-append directory "/" name)
                             inputs)))))
      (and (raises? (lock "from-git" `(dep (git ,dep))))
           ;; The same flake taken as a directory of this machine may.
           (lock "from-local" `(dep (local ,dep)))))))

(test-assert "the host does not read an input's files through a link"
  (with-workspace directory
    (let ((outside (string-append directory "/outside.scm"))
          (dep     (string-append directory "/dep")))
      (write-file outside (flake))
      (mkdir-p dep)
      (symlink outside (string-append dep "/flake.scm"))
      (commit! dep '("file" . "x"))
      (git dep "add" "flake.scm")
      (git dep "-c" "user.name=test" "-c" "user.email=test@example.org"
           "commit" "-q" "-m" "a link")
      (and (raises? (lock-flake
                     (project! (string-append directory "/project")
                               `(dep (git ,dep)))))
           ;; The control: with a file in the link's place, it locks.
           (begin
             (delete-file (string-append dep "/flake.scm"))
             (commit! dep `("flake.scm" . ,(flake)))
             (lock-flake
              (project! (string-append directory "/project")
                        `(dep (git ,dep)))))))))

;;;
;;; Local inputs and overrides.
;;;

(test-assert "a local input is recorded relative to the flake"
  (with-workspace directory
    (let* ((project (string-append directory "/project"))
           (dep     (string-append project "/deps/dep"))
           (commit  (commit! dep `("flake.scm" . ,(flake))))
           (lock    (lock-flake (project! project '(dep (local "deps/dep")))))
           (node    (node-of lock 'dep)))
      (and (string=? "deps/dep" (lock-node-path node))
           (string=? commit (lock-node-commit node))
           (not (string-contains
                 (contents (string-append project "/guix.lock"))
                 directory))
           ;; The lock is usable from another directory.
           (with-directory-excursion "/"
             (tree-file (lock-node-tree node project) "flake.scm"))))))

(test-equal "the state of a local checkout is told in one line each"
  '(0 1 1 1)
  (with-workspace directory
    (let* ((project (string-append directory "/project"))
           (dep     (string-append directory "/dep"))
           (tree    (string-append directory "/tree")))
      (commit! dep `("flake.scm" . ,(flake)))
      (commit! tree '("data" . "x"))
      (let* ((lock    (lock-flake
                       (project! project
                                 `(dep (local ,dep))
                                 `(tree (local ,tree) (worktree)
                                        (as source)))))
             (notices (lambda () (length (lock-notices lock project))))
             (clean   (notices)))
        (write-file (string-append dep "/flake.scm") (flake '(x (git "y"))))
        (let ((changed (notices)))
          (git dep "checkout" "flake.scm")
          (commit! dep '("new" . "file"))
          (let ((moved (notices)))
            (git dep "reset" "--hard" (lock-node-commit (node-of lock 'dep)))
            (write-file (string-append tree "/data") "y")
            (list clean changed moved (notices))))))))

(test-assert "an override leaves guix.lock as it is"
  (with-workspace directory
    (let* ((dep     (string-append directory "/dep"))
           (local   (string-append directory "/local"))
           (middle  (string-append directory "/middle"))
           (_       (commit! dep '(".guix-channel" . "(channel (version 0))")
                             '("is" . "remote")))
           (theirs  (commit! local
                             '(".guix-channel" . "(channel (version 0))")
                             '("is" . "local")))
           (_       (commit! middle
                             `("flake.scm" . ,(flake `(dep (git ,dep))))))
           (project (project! (string-append directory "/project")
                              `(dep (git ,dep) (as library))
                              `(middle (git ,middle))))
           (file    (string-append project "/guix.lock"))
           (_       (lock-flake project))
           (text    (contents file))
           (lock    (effective-flake-lock
                     project
                     #:overrides
                     `((dep . ,(parse-input-override 'dep local))))))
      (and (string=? text (contents file))
           (string=? theirs (lock-node-commit (node-of lock 'dep)))
           (eq? 'replaced (lock-edge-kind (edge-of lock 'dep)))
           ;; What the flake says about the input stays.
           (eq? 'library (lock-edge-as (edge-of lock 'dep)))
           ;; What follows the input follows the override.
           (string=? theirs (lock-node-commit (node-of lock 'middle 'dep)))
           ;; Without the override the lock is the committed one.
           (string=? text
                     (flake-lock->string (effective-flake-lock project)))
           (raises? (effective-flake-lock
                     project
                     #:overrides
                     `((absent . ,(parse-input-override 'absent local)))))))))

(test-assert "flake.local.scm redirects inputs, relative to the flake"
  (with-workspace directory
    (let* ((dep     (string-append directory "/dep"))
           (project (string-append directory "/project"))
           (local   (string-append project "/local"))
           (_       (commit! dep `("flake.scm" . ,(flake))))
           (theirs  (commit! local `("flake.scm" . ,(flake))))
           (_       (lock-flake (project! project `(dep (git ,dep)))))
           (text    (contents (string-append project "/guix.lock"))))
      (write-file (string-append project "/flake.local.scm")
                  "(flake-local (version 1) (inputs (dep (local \"local\"))))")
      (let ((lock (with-directory-excursion "/"
                    (effective-flake-lock project))))
        (and (string=? theirs (lock-node-commit (node-of lock 'dep)))
             (string=? text
                       (contents (string-append project "/guix.lock"))))))))

(test-equal "an override on the command line is a path or the fields"
  '((local "/some/where" #f) (git "https://example.org/x" "next"))
  (map (lambda (spec)
         (let ((input (parse-input-override 'x spec)))
           (list (flake-input-type input)
                 (or (flake-input-path input) (flake-input-url input))
                 (flake-input-branch input))))
       '("/some/where"
         "(git \"https://example.org/x\") (branch \"next\")")))


;;;
;;; Authentication.
;;;

(define (gpg+git-available?)
  (and (which (git-command))
       (which (gpg-command)) (which (gpgconf-command))))

(unless (gpg+git-available?)
  (test-skip 1))
(test-equal "an introduction authenticates the history, or refuses it"
  '(authenticated wrong-signer-refused unauthorized-commit-refused)
  (with-fresh-gnupg-setup (list %ed25519-public-key-file
                                %ed25519-secret-key-file
                                %ed25519-2-public-key-file
                                %ed25519-2-secret-key-file)
    (with-workspace directory
      (let* ((signer  (key-fingerprint %ed25519-public-key-file))
             (other   (key-fingerprint %ed25519-2-public-key-file))
             (dep     (string-append directory "/dep"))
             (key     (lambda (file)
                        (call-with-input-file file get-string-all)))
             (_       (populate-git-repository
                       dep
                       `((add "flake.scm" ,(flake))
                         (add ".guix-channel"
                              ,(object->string
                                '(channel (version 0)
                                          (keyring-reference "master"))))
                         (add ".guix-authorizations"
                              ,(object->string
                                `(authorizations
                                  (version 0)
                                  ((,signer (name "Charlie"))))))
                         (add "signer.key" ,(key %ed25519-public-key-file))
                         (add "other.key" ,(key %ed25519-2-public-key-file))
                         (commit "first" (signer ,signer))
                         (add "more" "content")
                         (commit "second" (signer ,signer)))))
             (start   (git dep "rev-list" "--max-parents=0" "HEAD"))
             (project (string-append directory "/project"))
             (declare (lambda (signer)
                        (project! project
                                  `(dep (git ,dep)
                                        (introduction (commit ,start)
                                                      (signer ,signer))))))
             (lock    (lock-flake (declare signer))))
        (list (and (equal? `((commit ,start) (signer ,signer))
                           (lock-node-authentication (node-of lock 'dep)))
                   'authenticated)
              ;; Another signer for the first commit.
              (and (raises? (lock-flake (declare other) #:update #t))
                   'wrong-signer-refused)
              ;; A commit by a key that is not authorized.
              (begin
                (populate-git-repository
                 dep `((add "evil" "content")
                       (commit "third" (signer ,other))))
                (and (raises? (lock-flake (declare signer) #:update #t))
                     'unauthorized-commit-refused)))))))

(test-assert "a Nix flake.lock alone leaves the Guix flake unlocked"
  ;; The Guix lock is guix.lock; flake.lock belongs to Nix (its JSON).  A
  ;; directory holding only a Nix flake.lock must be treated as unlocked, not
  ;; misread: the Guix code never reads flake.lock, and there is no fallback.
  (with-workspace directory
    (let* ((project (project! (string-append directory "/project")))
           (nix-lock "{\"nodes\":{\"nixpkgs\":{\"locked\":{\
\"lastModified\":1794386569,\"narHash\":\"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAA\\
AAAAAAAAAAAAAAAAAAAAAAAAA=\",\"owner\":\"NixOS\",\"repo\":\"nixpkgs\",\"rev\":\
\"0000000000000000000000000000000000000000\",\"type\":\"github\"}}},\"root\":\
\"nixpkgs\",\"version\":7}"))
      ;; A Nix flake.lock (JSON), and no guix.lock.
      (write-file (string-append project "/flake.lock") nix-lock)
      (let ((lock (effective-flake-lock project)))
        (and (flake-lock? lock)
             ;; Unlocked: no inputs, no nodes — the Nix lock was not read.
             (null? (flake-lock-inputs lock))
             (null? (flake-lock-nodes lock))
             ;; The Nix file is untouched, and no guix.lock was conjured.
             (string=? nix-lock (contents (string-append project "/flake.lock")))
             (not (file-exists? (string-append project "/guix.lock"))))))))

(test-assert "a Nix flake.lock is not read even when the flake has inputs"
  ;; With inputs and only a Nix flake.lock, the flake is still unlocked: the
  ;; code asks for guix.lock and refuses, rather than misreading Nix's JSON.
  (with-workspace directory
    (let* ((dep     (string-append directory "/dep"))
           (_       (commit! dep `("flake.scm" . ,(flake))))
           (project (project! (string-append directory "/project")
                              `(dep (git ,dep)))))
      (write-file (string-append project "/flake.lock")
                  "{\"nodes\":{},\"root\":\"nixpkgs\",\"version\":7}")
      (and (raises? (effective-flake-lock project))
           (not (file-exists? (string-append project "/guix.lock")))))))

(test-end "flakes")

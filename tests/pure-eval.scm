;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 the Guix authors

(define-module (test-pure-eval)
  #:use-module (guix pure-eval)
  #:use-module (guix store)
  #:use-module (guix tests)
  #:use-module ((guix diagnostics) #:select (formatted-message?))
  #:use-module ((guix utils) #:select (call-with-temporary-directory))
  #:use-module (guix build utils)
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-34)
  #:use-module (srfi srfi-64))

;;; The evaluator of '--pure-eval': what it is shown and what it is not.

(test-begin "pure-eval")

(define %store (open-connection-for-tests))

(define (entries directory)
  (scandir directory (lambda (file) (not (member file '("." ".."))))))

(define (call-with-project proc)
  "Call PROC with a Git work tree that tracks 'tracked.scm', a symbolic link
and a file in a directory, and that holds one more file it does not track."
  ;; Below the current directory: the container gets a /tmp of its own.
  (let ((project (string-append (getcwd) "/t-pure-eval-"
                                (number->string (getpid)))))
    (dynamic-wind
      (lambda ()
        (mkdir-p (string-append project "/directory"))
        (with-directory-excursion project
          (call-with-output-file "tracked.scm"
            (lambda (port) (display "tracked\n" port)))
          (call-with-output-file "untracked.scm"
            (lambda (port) (display "untracked\n" port)))
          (call-with-output-file "directory/file"
            (lambda (port) (display "below\n" port)))
          (symlink "tracked.scm" "link")
          (invoke "git" "init" "-q")
          (invoke "git" "add" "tracked.scm" "link" "directory/file")))
      (lambda () (proc project))
      (lambda () (delete-file-recursively project)))))

(test-equal "a tracked tree holds the tracked files and nothing else"
  '(("directory" "link" "tracked.scm") ("file") "tracked.scm")
  (call-with-project
   (lambda (project)
     (let ((tree (import-tracked-tree %store project)))
       (list (entries tree)
             (entries (string-append tree "/directory"))
             (readlink (string-append tree "/link")))))))

(test-equal "a tracked tree has the contents of the work tree"
  "changed\n"
  (call-with-project
   (lambda (project)
     (call-with-output-file (string-append project "/tracked.scm")
       (lambda (port) (display "changed\n" port)))
     (call-with-input-file
         (string-append (import-tracked-tree %store project) "/tracked.scm")
       (@ (ice-9 textual-ports) get-string-all)))))

(test-assert "a file outside every checkout is refused"
  (call-with-temporary-directory
   (lambda (directory)
     (let ((file (string-append directory "/plain.scm")))
       (call-with-output-file file (const #t))
       (guard (c ((formatted-message? c) #t))
         (import-projects %store (list file))
         #f)))))

;; The tests below start the evaluator.
(unless (pure-eval-supported?)
  (test-skip 12))

(test-equal "a value comes back"
  '(1 "two" three (4 . #t))
  (evaluate-in-container ''(1 "two" three (4 . #t))))

(test-equal "what the code prints is not the value"
  42
  (evaluate-in-container '(begin (display "noise") (newline) 42)))

(test-equal "the environment is made from nothing"
  '(#f "/tmp")
  (begin
    (setenv "PURE_EVAL_PROBE" "set")
    (evaluate-in-container '(list (getenv "PURE_EVAL_PROBE")
                                  (getenv "HOME")))))

(test-equal "the host's files are not there"
  '(#t #f)
  (call-with-temporary-output-file
   (lambda (file port)
     (list (file-exists? file)
           (evaluate-in-container `(file-exists? ,file))))))

(test-equal "what the caller has open is not inherited"
  '(#t #f)
  (call-with-temporary-output-file
   (lambda (file port)
     (fcntl port F_SETFD 0)                       ;let it cross an 'exec'
     ;; The number may be in use in the evaluator; it must not be this file.
     (let* ((descriptor (fileno port))
            (inode      (stat:ino (stat port)))
            (same-file? `(let ((st (false-if-exception (stat ,descriptor))))
                           (and st (= (stat:ino st) ,inode)))))
       (list (primitive-eval same-file?)
             (evaluate-in-container same-file?))))))

(test-equal "what the caller had buffered is written once"
  "buffered"
  ;; The evaluator starts as a copy of the caller, buffers included.
  (call-with-temporary-output-file
   (lambda (file port)
     (setvbuf port 'block 4096)
     (display "buffered" port)
     (evaluate-in-container ''done)
     (force-output port)
     (call-with-input-file file (@ (ice-9 textual-ports) get-string-all)))))

(test-equal "the host name is fixed"
  "localhost"
  (evaluate-in-container '(gethostname)))

(test-equal "the host's network is not reachable"
  '(connected unreachable)
  (let ((server (socket AF_INET SOCK_STREAM 0)))
    (dynamic-wind
      (const #t)
      (lambda ()
        (bind server AF_INET INADDR_LOOPBACK 0)
        (listen server 1)
        (let* ((port    (sockaddr:port (getsockname server)))
               (attempt `(catch 'system-error
                           (lambda ()
                             (let ((client (socket AF_INET SOCK_STREAM 0)))
                               (connect client AF_INET INADDR_LOOPBACK ,port)
                               'connected))
                           (lambda _ 'unreachable))))
          ;; The first is the control: the same code, evaluated here.
          (list (primitive-eval attempt)
                (evaluate-in-container attempt))))
      (lambda () (close-port server)))))

(test-equal "a project is shown where it is, without its untracked files"
  '("tracked\n" "below\n" #f)
  (call-with-project
   (lambda (project)
     (let ((tracked   (string-append project "/tracked.scm"))
           (below     (string-append project "/directory/file"))
           (untracked (string-append project "/untracked.scm")))
       (evaluate-in-container
        `(let ((contents (lambda (file)
                           (call-with-input-file file
                             (@ (ice-9 textual-ports) get-string-all)))))
           (list (contents ,tracked) (contents ,below)
                 (file-exists? ,untracked)))
        #:projects (import-projects %store (list tracked)))))))

(test-equal "the evaluator starts in the directory of the caller"
  "below\n"
  (call-with-project
   (lambda (project)
     (evaluate-in-container
      '(call-with-input-file "file" (@ (ice-9 textual-ports) get-string-all))
      #:projects (import-projects %store
                                  (list (string-append project
                                                       "/tracked.scm")))
      #:directory (string-append project "/directory")))))

(test-assert "an error in the evaluator is an error here"
  (guard (c ((formatted-message? c) #t))
    (evaluate-in-container '(error "raised in the evaluator"))
    #f))

(test-assert "an evaluator that leaves without an answer is an error"
  (guard (c ((formatted-message? c) #t))
    (evaluate-in-container '(primitive-exit 0))
    #f))

;; Where no container can be made, the environment is still made from
;; nothing; the file system is the host's.
(test-equal "without a container the environment is scrubbed"
  '(#f #t)
  (call-with-temporary-output-file
   (lambda (file port)
     (setenv "PURE_EVAL_PROBE" "set")
     (evaluate-in-container `(list (getenv "PURE_EVAL_PROBE")
                                   (file-exists? ,file))
                            #:container? #f))))

(test-end "pure-eval")

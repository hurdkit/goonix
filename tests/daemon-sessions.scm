;;; goonix: the sessions a build daemon reports itself, and 'guix processes'
;;; with a daemon that reports none.
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (test-daemon-sessions)
  #:use-module (guix daemon-sessions)
  #:use-module (guix scripts processes)
  #:use-module (guix store)
  #:use-module ((guix remote-procedures) #:select (%protocol-version))
  #:use-module (guix serialization)
  #:use-module (guix derivations)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix tests)
  #:use-module ((guix utils) #:select (call-with-temporary-directory))
  #:use-module (gnu packages bootstrap)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-34)
  #:use-module (srfi srfi-64)
  #:use-module (ice-9 match)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 threads))

;;; The first tests need no daemon: they are about the answer's layout,
;;; about which of the sessions it names are kept, about which daemon is
;;; asked, and about what 'guix processes' prints for a session that a daemon
;;; reported and for one read in /proc.  The others run with the test suite's
;;; daemon, whichever it is, and state what holds for a daemon that reports
;;; its sessions and for one whose sessions are read in /proc: each
;;; connection of this process is one session, and asking adds none.

(test-begin "daemon-sessions")

(define (session->list session)
  (list (reported-session-id session)
        (reported-session-client session)
        (reported-session-locks session)
        (reported-session-children session)))

(define (report->list report)
  (and report
       (cons (daemon-report-pid report)
             (map session->list (daemon-report-sessions report)))))

(test-equal "answer: a daemon without sessions"
  '(4242)
  (report->list (string-list->daemon-report '("1" "4242"))))

(test-equal "answer: sessions with and without locks and children"
  '(4242
    (1 100 ("/gnu/store/a.lock" "/gnu/store/b.lock") (201 202))
    (2 100 () ())
    (7 300 () (203)))
  (report->list
   (string-list->daemon-report
    '("1" "4242"
      "1" "100" "2" "/gnu/store/a.lock" "/gnu/store/b.lock" "2" "201" "202"
      "2" "100" "0" "0"
      "7" "300" "0" "1" "203"))))

(test-equal "answer: what is not understood is no answer"
  '(#f #f #f #f #f #f #f #f #f)
  (map string-list->daemon-report
       '(()                                       ;nothing
         ("1")                                    ;no daemon
         ("2" "4242")                             ;another layout
         ("1" "daemon")                           ;not a PID
         ("1" "4242" "1")                         ;a session cut short
         ("1" "4242" "1" "100" "2" "/a.lock")     ;fewer locks than announced
         ("1" "4242" "1" "100" "0")               ;no count of children
         ("1" "4242" "1" "100" "0" "1" "child")   ;a child that is not a PID
         ("1" "4242" "1" "100" "0" "0" "9"))))    ;a session cut short

;; A process table as (guix scripts processes) has it, reduced to what the
;; code under test may ask of it: PID, parent, and nothing else.
(define %processes
  '((1 . 0) (4242 . 1) (100 . 1) (201 . 4242) (202 . 1) (300 . 1)))

(define (lookup-process pid)
  (assv pid %processes))

(define (lookup-children pid)
  (filter (match-lambda ((_ . parent) (eqv? parent pid)))
          %processes))

(define (sessions report)
  (reported-daemon-sessions list lookup-process lookup-children report))

(test-equal "sessions: no report, no sessions"
  '()
  (sessions #f))

(test-equal "sessions: the daemon is not among the processes"
  '()
  (sessions (string-list->daemon-report
             '("1" "5555" "1" "100" "0" "0"))))

(test-equal "sessions: a session whose client is gone is left out"
  '(((4242 . 1) (300 . 1) () ()))
  (sessions (string-list->daemon-report
             '("1" "4242" "1" "999" "0" "0" "2" "300" "0" "0"))))

(test-equal "sessions: of the children named, the daemon's own are kept"
  ;; 201 is a child of the daemon; 202 is a process, but not its child; 203
  ;; is no process.
  '(((4242 . 1) (100 . 1) ((201 . 4242)) ("/gnu/store/a.lock")))
  (sessions (string-list->daemon-report
             '("1" "4242"
               "1" "100" "1" "/gnu/store/a.lock" "3" "201" "202" "203"))))


;;;
;;; Which daemon is asked.
;;;

(define %stderr-last #x616c7473)

(define (asked-of-daemon version answer)
  "Run a daemon that sends VERSION as its version in the greeting and answers
'query-sessions' with ANSWER, a list of strings, and ask it with
'query-daemon-report'.  Return two values: the operations it was asked for,
and what 'query-daemon-report' returned."
  (call-with-temporary-directory
   (lambda (directory)
     (let ((file   (string-append directory "/socket"))
           (server (socket PF_UNIX SOCK_STREAM 0)))
       (define (serve)
         (match (accept server)
           ((port . _)
            (let ((operations
                   (guard (c ((nar-error? c) 'no-greeting))
                     ;; The greeting, as (guix store) expects it.
                     (read-int port)
                     (write-int #x6478696f port)
                     (write-int version port)
                     (force-output port)
                     (read-int port)              ;the client's version
                     (unless (zero? (read-int port)) ;CPU affinity
                       (read-int port))
                     (read-int port)              ;reserve space
                     (write-int %stderr-last port)
                     (force-output port)
                     (let loop ((operations '()))
                       (match (guard (c ((nar-error? c) #f))
                                (read-int port))
                         (#f (reverse operations))
                         (85
                          (write-int %stderr-last port)
                          (write-string-list answer port)
                          (force-output port)
                          (loop (cons 85 operations)))
                         (operation
                          (reverse (cons operation operations))))))))
              (close-port port)
              operations))))

       (bind server AF_UNIX file)
       (listen server 1)
       (let* ((thread (call-with-new-thread serve))
              (report (query-daemon-report file))
              (asked  (join-thread thread (+ (current-time) 60) 'no-client)))
         (close-port server)
         (values asked report))))))

;; What a goonix daemon sets above its protocol version in the greeting, and
;; the versions that goonix daemons announced before they gave that signal,
;; written out: these are what daemons that exist send.  The question goes
;; with the signal, not with a version: upstream may give any of these
;; numbers a meaning of its own.
(define %signal #x67010000)
(define %versions-before-the-signal '(#x165 #x166 #x167))

(test-equal "a daemon that gives no signal is not asked, whatever its version"
  '((() #f) (() #f) (() #f) (() #f))
  (map (lambda (version)
         (let-values (((asked report)
                       (asked-of-daemon version
                                        '("1" "4242" "3" "100" "0" "0"))))
           (list asked (report->list report))))
       (cons %protocol-version %versions-before-the-signal)))

(test-equal "a daemon that gives the signal is asked"
  '((85) (4242 (3 100 () ())))
  (let-values (((asked report)
                (asked-of-daemon (logior %signal %protocol-version)
                                 '("1" "4242" "3" "100" "0" "0"))))
    (list asked (report->list report))))


;;;
;;; What is printed.
;;;

;; The processes of one machine: a daemon that reports its sessions (4242)
;; with a builder (201), a daemon that has a process per session (4300, with
;; the session process 4310 and its builder 4311), and a client (100).
(define (printed-processes)
  (let ((process (@@ (guix scripts processes) process)))
    (list (process 4242 1 '("guix-daemon" "--listen=/one"))
          (process 201 4242 '("guile" "builder"))
          (process 4300 1 '("guix-daemon" "--listen=/two"))
          (process 4310 4300 '("guix-daemon" "100" "--listen=/two"))
          (process 4311 4310 '("bash" "-e" "builder.sh"))
          (process 100 1 '("guix" "build" "hello")))))

(define (reported-sessions processes)
  "Return the two sessions that daemon 4242 of PROCESSES reports: number 7,
which builds, and number 9, which is idle."
  (reported-daemon-sessions
   (@@ (guix scripts processes) daemon-session)
   (lambda (pid)
     (find (lambda (process) (= pid (process-id process))) processes))
   (lambda (pid)
     (filter (lambda (process) (eqv? pid (process-parent-id process)))
             processes))
   (string-list->daemon-report
    '("1" "4242"
      "7" "100" "1" "/gnu/store/a.lock" "1" "201"
      "9" "100" "0" "0"))))

(define (session-in-proc processes)
  "Return the session of daemon 4300 of PROCESSES, as 'daemon-sessions' makes
it from /proc."
  (define (lookup pid)
    (find (lambda (process) (= pid (process-id process))) processes))
  ((@@ (guix scripts processes) daemon-session)
   (lookup 4310) (lookup 100) (list (lookup 4311)) '("/gnu/store/b.lock")))

(define (recutils sessions)
  (call-with-output-string
    (lambda (port)
      ((@@ (guix scripts processes) daemon-sessions->recutils)
       port sessions))))

(define (normalized sessions)
  (call-with-output-string
    (lambda (port)
      ((@@ (guix scripts processes) daemon-sessions->normalized-record)
       port sessions))))

;; What upstream's 'guix processes' prints for the session read in /proc, in
;; its two formats.
(define %upstream-recutils "\
SessionPID: 4310
ClientPID: 100
ClientCommand: guix build hello
LockHeld: /gnu/store/b.lock
ChildPID: 4311
ChildCommand: : bash -e builder.sh

")

(define %upstream-normalized "\
%rec: Session
%type: PID int
%type: ClientPID int
%key: PID
%mandatory: ClientPID ClientCommand

PID: 4310
ClientPID: 100
ClientCommand: guix build hello

%rec: Lock
%mandatory: LockHeld
%type: Session rec Session

LockHeld: testing testing
Session: 4310

%rec: ChildProcess
%type: PID int
%type: Session rec Session
%key: PID
%mandatory: Command

PID: 4311
Command: bash -e builder.sh
Session: 4310

")

(test-equal "printed: a session read in /proc has no number"
  #f
  (session-number (session-in-proc (printed-processes))))

(test-equal "printed: a session read in /proc, as upstream prints it"
  %upstream-recutils
  (recutils (list (session-in-proc (printed-processes)))))

(test-equal "printed: a session read in /proc, normalized as upstream prints it"
  %upstream-normalized
  (normalized (list (session-in-proc (printed-processes)))))

(test-equal "printed: the sessions a daemon reported have its numbers"
  '(7 9)
  (map session-number (reported-sessions (printed-processes))))

(test-equal "printed: the sessions a daemon reported, each with its number"
  "\
SessionPID: 4242
SessionNumber: 7
ClientPID: 100
ClientCommand: guix build hello
LockHeld: /gnu/store/a.lock
ChildPID: 201
ChildCommand: : guile builder

SessionPID: 4242
SessionNumber: 9
ClientPID: 100
ClientCommand: guix build hello

"
  (recutils (reported-sessions (printed-processes))))

(test-equal "printed: the sessions a daemon reported, normalized, each with a key of its own"
  "\
%rec: Session
%type: ClientPID int
%key: PID
%mandatory: ClientPID ClientCommand

PID: 4242-7
ClientPID: 100
ClientCommand: guix build hello

PID: 4242-9
ClientPID: 100
ClientCommand: guix build hello

%rec: Lock
%mandatory: LockHeld
%type: Session rec Session

LockHeld: testing testing
Session: 4242-7

%rec: ChildProcess
%type: PID int
%type: Session rec Session
%key: PID
%mandatory: Command

PID: 201
Command: guile builder
Session: 4242-7

"
  (normalized (reported-sessions (printed-processes))))

(test-equal "printed: beside reported sessions, a session read in /proc is printed as upstream prints it"
  (string-append %upstream-recutils "\
SessionPID: 4242
SessionNumber: 9
ClientPID: 100
ClientCommand: guix build hello

")
  (let ((processes (printed-processes)))
    (recutils (list (session-in-proc processes)
                    (second (reported-sessions processes))))))

(test-equal "printed: beside reported sessions, normalized, a session read in /proc keeps its records"
  "\
%rec: Session
%type: ClientPID int
%key: PID
%mandatory: ClientPID ClientCommand

PID: 4310
ClientPID: 100
ClientCommand: guix build hello

PID: 4242-9
ClientPID: 100
ClientCommand: guix build hello

%rec: Lock
%mandatory: LockHeld
%type: Session rec Session

LockHeld: testing testing
Session: 4310

%rec: ChildProcess
%type: PID int
%type: Session rec Session
%key: PID
%mandatory: Command

PID: 4311
Command: bash -e builder.sh
Session: 4310

"
  (let ((processes (printed-processes)))
    (normalized (list (session-in-proc processes)
                      (second (reported-sessions processes))))))


;;;
;;; With the test suite's daemon.
;;;

(define (mine? session)
  (= (getpid) (process-id (daemon-session-client session))))

(test-assert "the daemon gives the signal and answers the question"
  ;; The daemon it names is one that listens, not a session process.
  (let ((report (query-daemon-report)))
    (and (with-store store
           (positive? (store-connection-goonix-level store)))
         (daemon-report? report)
         (let-values (((sessions listening) (daemon-sessions)))
           (->bool (memv (daemon-report-pid report)
                         (map process-id listening)))))))

(test-assert "a session of this process is printed with a number if and only if its daemon reported it"
  ;; A reported session is a session of the listening process, and is
  ;; printed with the number that tells it apart.  A session read in /proc
  ;; has a process of its own, and is printed as upstream prints it.
  (with-store store
    (let-values (((sessions listening) (daemon-sessions)))
      (match (filter mine? sessions)
        ((session)
         (let* ((pid    (process-id (daemon-session-process session)))
                (text   (recutils (list session)))
                (client (format #f "ClientPID: ~a~%ClientCommand:~a~%~%"
                                (getpid)
                                (string-concatenate
                                 (map (lambda (word)
                                        (string-append " " word))
                                      (process-command
                                       (daemon-session-client session)))))))
           (if (memq (daemon-session-process session) listening)
               (match (string-match "^SessionPID: [0-9]+\nSessionNumber: ([0-9]+)\n"
                                    text)
                 (#f #f)
                 (m
                  (let ((number (match:substring m 1)))
                    (and (string=? text
                                   (format #f "SessionPID: ~a~%SessionNumber: ~a~%~a"
                                           pid number client))
                         (string-prefix?
                          (format #f "%rec: Session~%%type: ClientPID int~%%key: PID~%%mandatory: ClientPID ClientCommand~%~%PID: ~a-~a~%~a%rec: Lock~%"
                                  pid number client)
                          (normalized (list session)))))))
               (and (string=? text
                              (format #f "SessionPID: ~a~%~a" pid client))
                    (string-prefix?
                     (format #f "%rec: Session~%%type: PID int~%%type: ClientPID int~%%key: PID~%%mandatory: ClientPID ClientCommand~%~%PID: ~a~%~a%rec: Lock~%"
                             pid client)
                     (normalized (list session)))))))
        (_ #f)))))

(define (sessions-of-this-process)
  (count mine? (daemon-sessions)))

(test-equal "no connection, no session of this process"
  0
  (sessions-of-this-process))

(test-equal "asking the daemon leaves no session of this process"
  0
  (begin
    (query-daemon-report)
    (query-daemon-report)
    (sessions-of-this-process)))

(test-equal "one connection, one session of this process"
  1
  (with-store store
    (sessions-of-this-process)))

(test-equal "two connections, two sessions of this process"
  2
  (with-store one
    (with-store two
      (sessions-of-this-process))))

(test-assert "a connection is served after the daemon was asked"
  ;; A daemon that does not know the question ends the connection it was
  ;; asked on.  That connection is not this one.
  (with-store store
    (let ((item (add-text-to-store store "before" (random-text))))
      (query-daemon-report)
      (daemon-sessions)
      (and (valid-path? store item)
           (valid-path? store
                        (add-text-to-store store "after" (random-text)))))))

(test-assert "a new connection is served after the daemon was asked"
  (begin
    (query-daemon-report)
    (with-store store
      (valid-path? store (add-text-to-store store "later" (random-text))))))

(test-assert "the session of a build in flight has its lock and a child"
  ;; This does not go through files that the builder and the test share, so
  ;; it also runs where builds are isolated.  The lock file is there from
  ;; before the daemon waits for the lock until the build is over.
  (with-store store
    (let* ((exp    #~(begin #$(random-text) (sleep 10) (mkdir #$output)))
           (guile  (package-derivation store %bootstrap-guile))
           (drv    (run-with-store store
                     (gexp->derivation "session-build" exp
                                       #:guile-for-build guile)))
           (lock   (string-append (derivation->output-path drv) ".lock"))
           (thread (call-with-new-thread
                    (lambda ()
                      (build-derivations store (list drv))))))
      (let loop ((tries 0))
        (unless (or (file-exists? lock) (> tries 6000))
          (usleep 10000)
          (loop (+ tries 1))))
      ;; The builder starts some time after the lock is taken: look until
      ;; a session of this process has the lock and a child, for less long
      ;; than the builder runs.  This process may have more than one session
      ;; for a moment: a daemon that has a process per session forks that
      ;; process to start a builder, and until the child runs the builder
      ;; /proc shows it with the session's command line.
      (let ((seen? (let loop ((tries 0))
                     (or (any (lambda (session)
                                (and (member lock
                                             (daemon-session-locks-held
                                              session))
                                     (pair? (daemon-session-children session))
                                     (every process?
                                            (daemon-session-children
                                             session))))
                              (filter mine? (daemon-sessions)))
                         (and (< tries 30)
                              (begin
                                (usleep 200000)
                                (loop (+ tries 1))))))))
        (join-thread thread)
        (->bool seen?)))))

(test-end "daemon-sessions")

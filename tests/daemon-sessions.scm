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
  #:use-module (guix derivations)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix tests)
  #:use-module (gnu packages bootstrap)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-64)
  #:use-module (ice-9 match)
  #:use-module (ice-9 threads))

;;; The first tests need no daemon: they are about the answer's layout and
;;; about which of the sessions it names are kept.  The others run with the
;;; test suite's daemon, whichever it is, and state what holds for a daemon
;;; that reports its sessions and for one whose sessions are read in /proc:
;;; each connection of this process is one session, and asking adds none.

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

(define (mine? session)
  (= (getpid) (process-id (daemon-session-client session))))

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
      ;; the session has a child, for less long than the builder runs.
      (let ((seen? (let loop ((tries 0))
                     (match (filter mine? (daemon-sessions))
                       ((session)
                        (or (and (member lock
                                         (daemon-session-locks-held session))
                                 (pair? (daemon-session-children session))
                                 (every process?
                                        (daemon-session-children session)))
                            (and (< tries 30)
                                 (begin
                                   (usleep 200000)
                                   (loop (+ tries 1))))))
                       (_ #f)))))
        (join-thread thread)
        (->bool seen?)))))

(test-end "daemon-sessions")

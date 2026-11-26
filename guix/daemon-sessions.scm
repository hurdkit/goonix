;;; goonix: the sessions a build daemon reports itself.
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

(define-module (guix daemon-sessions)
  #:use-module (guix store)
  #:use-module ((guix serialization) #:select (nar-error?))
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-34)
  #:use-module (ice-9 match)
  #:use-module (ice-9 binary-ports)
  #:use-module (web uri)
  #:export (daemon-report?
            daemon-report-pid
            daemon-report-sessions

            reported-session?
            reported-session-id
            reported-session-client
            reported-session-locks
            reported-session-children

            string-list->daemon-report
            query-daemon-report
            reported-daemon-sessions))

;;; Commentary:
;;;
;;; 'guix processes' finds the sessions of the C++ daemon in /proc: that
;;; daemon serves each client from a process of its own, which has the
;;; client's PID as its second argument, the lock files of its builds among
;;; its open files and its builders among its children.
;;;
;;; A daemon that serves every client from one process shows none of this.
;;; All of its sessions are one PID, its open files and its children belong
;;; to no session in particular, and its command line names no client.  Only
;;; the daemon knows its sessions, so it is asked: the 'query-sessions'
;;; remote procedure returns them.
;;;
;;; A daemon that does not know that procedure, the C++ daemon and upstream's
;;; among them, answers with an error.  That, a connection that fails or
;;; ends, and an answer this module cannot read all mean the same here: the
;;; daemon reports no sessions, and what /proc shows is all there is.  The
;;; question is put on a connection opened for it and closed afterwards, so a
;;; daemon that ends the session of a client asking for an unknown operation
;;; (the C++ daemon does) ends nothing else.
;;;
;;; Code:

;; What a daemon said about itself.
(define-record-type <daemon-report>
  (daemon-report pid sessions)
  daemon-report?
  (pid       daemon-report-pid)                   ;integer
  (sessions  daemon-report-sessions))             ;list of <reported-session>

;; One session of a reporting daemon.  ID tells the sessions of one daemon
;; apart; the daemon's PID does not, since they all have it.
(define-record-type <reported-session>
  (reported-session id client locks children)
  reported-session?
  (id        reported-session-id)                 ;integer
  (client    reported-session-client)             ;integer, the client's PID
  (locks     reported-session-locks)              ;list of file names
  (children  reported-session-children))          ;list of integers, PIDs

(define %report-version 1)

(define (string-list->daemon-report strings)
  "Return the <daemon-report> that STRINGS, the answer to 'query-sessions',
denotes, or #f if it is not one this code understands.

STRINGS starts with the version of the layout and the daemon's PID.  Then,
for each session: its identifier, the PID of its client, the number of its
lock files followed by their names, and the number of its child processes
followed by their PIDs.  Numbers are in decimal."
  (define (number str)
    (and (string? str)
         (not (string-null? str))
         (string-every char-set:digit str)
         (string->number str)))

  (define (take-counted lst)
    ;; LST starts with a count and that many elements.  Return the elements
    ;; and what follows them, or #f and #f.
    (match lst
      (((= number (? integer? count)) rest ...)
       (if (<= count (length rest))
           (split-at rest count)
           (values #f #f)))
      (_ (values #f #f))))

  (define (sessions lst)
    ;; Return the list of sessions LST denotes, or #f.
    (let loop ((lst lst)
               (result '()))
      (match lst
        (()
         (reverse result))
        (((= number (? integer? id)) (= number (? integer? client)) rest ...)
         (let*-values (((locks rest) (take-counted rest))
                       ((children rest) (if rest
                                            (take-counted rest)
                                            (values #f #f))))
           (let ((children (and children (map number children))))
             (and locks children (every integer? children)
                  (loop rest
                        (cons (reported-session id client locks children)
                              result))))))
        (_ #f))))

  (match strings
    (((= number version) (= number (? integer? pid)) rest ...)
     (and (eqv? version %report-version)
          (and=> (sessions rest)
                 (lambda (sessions)
                   (daemon-report pid sessions)))))
    (_ #f)))

(define (local-socket? uri)
  "Return true if URI, a string as taken by 'open-connection', denotes a
Unix-domain socket of this machine."
  (match (string->uri uri)
    (#f #t)                                       ;a file name
    (uri (and (memq (uri-scheme uri) '(#f file unix)) #t))))

(define* (query-daemon-report #:optional (uri (%daemon-socket-uri)))
  "Ask the daemon at URI for its sessions and return its <daemon-report>.
Return #f if it gives none: no daemon answers at URI, the daemon does not know
the question, or URI denotes another machine, whose processes are not those
'guix processes' lists.  The connection this opens is not among the sessions
of the report."
  (define (close store)
    ;; Wait until the daemon has let go of the connection.  The C++ daemon
    ;; serves it from a process that carries the PID of its client, this
    ;; process, as its second argument, and that process ends once it has
    ;; refused the question; its end is the end of file here.  Returning
    ;; earlier would leave it for the next reader of /proc to take for a
    ;; session of this process.  Any daemon ends a connection whose client
    ;; has finished writing.
    (let ((port (store-connection-socket store)))
      (false-if-exception
       (begin
         (force-output port)
         (shutdown port 1)
         (let loop ()
           (unless (eof-object? (get-u8 port))
             (loop)))))
      (false-if-exception (close-port port))))

  (define (ask store)
    (catch 'system-error
      (lambda ()
        (guard (c ((or (store-error? c) (nar-error? c)) #f))
          (string-list->daemon-report (query-sessions store))))
      (const #f)))

  (and (local-socket? uri)
       (let ((store (catch 'system-error
                      (lambda ()
                        (guard (c ((or (store-error? c) (nar-error? c)) #f))
                          (open-connection uri)))
                      (const #f))))
         (and store
              (let ((report (ask store)))
                (close store)
                report)))))

(define* (reported-daemon-sessions make-session lookup-process lookup-children
                                   #:optional (report (query-daemon-report)))
  "Return the sessions of REPORT, a <daemon-report> or #f, as made by
MAKE-SESSION, the constructor of (guix scripts processes): a procedure of the
daemon's process, the client's process, the list of child processes and the
list of lock files.

LOOKUP-PROCESS returns the process with the given PID among those read from
/proc, or #f; LOOKUP-CHILDREN returns the list of those whose parent has the
given PID.  A session whose client is not among them is left out, as is every
session of a daemon that is not among them: its PIDs are those of another
machine or another PID name space.  Of the child processes a session names,
those that are children of the daemon in /proc are kept."
  (match report
    (#f '())
    (($ <daemon-report> pid sessions)
     (match (lookup-process pid)
       (#f '())
       (daemon
        (let ((children (lookup-children pid)))
          (define (child pid)
            (let ((process (lookup-process pid)))
              (and process (memq process children) process)))

          (filter-map (lambda (session)
                        (and=> (lookup-process
                                (reported-session-client session))
                               (lambda (client)
                                 (make-session
                                  daemon client
                                  (filter-map child
                                              (reported-session-children
                                               session))
                                  (reported-session-locks session)))))
                      sessions)))))))

;;; daemon-sessions.scm ends here

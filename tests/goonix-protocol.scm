;;; goonix: the signal by which a goonix daemon and client know each other.
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

(define-module (test-goonix-protocol)
  #:use-module (guix store)
  #:use-module (guix remote-procedures)
  #:use-module (guix serialization)
  #:use-module (guix tests)
  #:use-module ((guix utils) #:select (call-with-temporary-directory))
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-34)
  #:use-module (srfi srfi-64)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 threads)
  #:use-module ((web client) #:select (http-get))
  #:use-module ((web response) #:select (response-code))
  #:use-module ((web uri) #:select (string->uri)))

;;; The operations and the setting that upstream's worker protocol does not
;;; have are used on a connection only when both of its ends gave the signal
;;; of goonix in the greeting.  The first tests are about the client, with
;;; daemons made here that record what they are sent: one that gives no
;;; signal is sent upstream's conversation, whatever version it announces.
;;; The others are about the test suite's daemon, whichever it is, with
;;; greetings written here byte by byte: a client that gives no signal gets
;;; upstream's conversation from it.
;;;
;;; The module of the signal is looked up when a test runs and the words of
;;; the greeting are written out, so that this file also loads with a client
;;; that has no signal and says what that client does.

(test-begin "goonix-protocol")

(define %stderr-next  #x6f6c6d67)
(define %stderr-last  #x616c7473)
(define %stderr-error #x63787470)

;; What a goonix peer sets above the sixteen bits of the protocol version:
;; the tag, and the level of the peers that exist.
(define %tag #x67)
(define %signal #x67010000)

(define (word-version word) (logand word #xffff))
(define (word-tag word) (logand (ash word -24) #xff))
(define (word-level word) (logand (ash word -16) #xff))

;; The operations of goonix, by identifier, and one that no daemon has.
(define %goonix-operations '(82 83 84 85))
(define %no-operation 99)


;;;
;;; The words.
;;;

(define (protocol name)
  "Return the binding of NAME in the module of the signal."
  (module-ref (resolve-interface '(guix goonix-protocol)) name))

(define %source-directory
  (dirname (dirname (search-path %load-path "guix/store.scm"))))

(define (upstream-protocol-version)
  "Return the protocol version of the client in the commit of upstream that
this tree is based on, or #f if that commit cannot be read here."
  (false-if-exception
   (let* ((base (string-trim-both
                 (call-with-input-file
                     (string-append %source-directory
                                    "/build-aux/goonix-upstream-base")
                   get-string-all)))
          (pipe (open-pipe* OPEN_READ "git" "-C" %source-directory "show"
                            (string-append base
                                           ":guix/remote-procedures.scm"))))
     (let loop ()
       (match (read pipe)
         ((? eof-object?)
          (close-pipe pipe)
          #f)
         (('define '%protocol-version (? integer? version))
          (get-string-all pipe)
          (close-pipe pipe)
          version)
         (_
          (loop)))))))

(let ((upstream (upstream-protocol-version)))
  (unless upstream
    (test-skip 1))
  (test-equal "the protocol version is the one of upstream's commit"
    upstream
    %protocol-version))

(test-equal "the word of this client: the protocol version below the signal"
  (list %protocol-version %tag #t)
  (let ((word ((protocol 'goonix-version-word) %protocol-version)))
    (list (word-version word) (word-tag word) (positive? (word-level word)))))

(test-equal "the word of this client reads as upstream reads its own"
  (list (protocol-major %protocol-version) (protocol-minor %protocol-version))
  (let ((word ((protocol 'goonix-version-word) %protocol-version)))
    (list (protocol-major word) (protocol-minor word))))

(test-equal "a word without the tag has no level"
  '(0 0 0 0 0 0)
  ;; Upstream's versions, the versions that goonix daemons announced before
  ;; they gave a signal, and a word with other bits above the version.
  (map (protocol 'version-word-goonix-level)
       (list %protocol-version #x163 #x165 #x166 #x167
             (logior #x66010000 %protocol-version))))

(test-equal "a word with the tag has its level"
  '(1 2 0)
  (map (protocol 'version-word-goonix-level)
       (list (logior %signal %protocol-version)
             (logior #x67020000 %protocol-version)
             (logior #x67000000 %protocol-version))))

(test-equal "each operation of goonix needs a level, upstream's need none"
  '((#f #f #f #f) (#t #t #t #t) (#t #t #t #t))
  (let ((knows? (protocol 'goonix-level-knows?)))
    (list (map (lambda (operation) (knows? 0 operation)) %goonix-operations)
          (map (lambda (operation) (knows? 1 operation)) %goonix-operations)
          (map (lambda (operation) (knows? 0 operation)) '(1 7 19 81)))))


;;;
;;; What the client sends.
;;;

(define (call-with-recording-daemon word proc)
  "Run a daemon that sends WORD as its version in the greeting, answers
'set-options' and the operations of goonix, and ends the connection at any
other operation.  Call PROC with the file name of its socket.  Return three
values: what PROC returned; the word the client sent as its version; and what
the daemon was asked, a list of operation identifiers where 'set-options' is
a pair of its identifier and the alist of the settings it came with."
  (call-with-temporary-directory
   (lambda (directory)
     (let ((file   (string-append directory "/socket"))
           (server (socket PF_UNIX SOCK_STREAM 0)))
       (define (serve)
         (match (accept server)
           ((port . _)
            (let ((result
                   (guard (c ((nar-error? c) (list 'no-greeting '())))
                     (read-int port)
                     (write-int %worker-magic-2 port)
                     (write-int word port)
                     (force-output port)
                     (let ((client (read-int port)))
                       (unless (zero? (read-int port)) ;CPU affinity
                         (read-int port))
                       (read-int port)                 ;reserve space
                       (write-int %stderr-last port)
                       (force-output port)
                       (let loop ((asked '()))
                         (define (answered operation)
                           (force-output port)
                           (loop (cons operation asked)))

                         (match (guard (c ((nar-error? c) #f))
                                  (read-int port))
                           (#f
                            (list client (reverse asked)))
                           (19
                            (for-each (lambda (_) (read-int port)) (iota 9))
                            (let ((settings (read-string-pairs port)))
                              (write-int %stderr-last port)
                              (answered (cons 19 settings))))
                           (82
                            (read-string port)
                            (read-string port)
                            (write-int %stderr-last port)
                            (write-string "/gnu/store/realised" port)
                            (answered 82))
                           (83
                            (read-string port)
                            (read-string port)
                            (write-int %stderr-last port)
                            (write-string-list '() port)
                            (answered 83))
                           (84
                            (read-string port)
                            (write-int %stderr-last port)
                            (write-string-list '() port)
                            (write-string-list '() port)
                            (answered 84))
                           (85
                            (write-int %stderr-last port)
                            (write-string-list '("1" "4242") port)
                            (answered 85))
                           (operation
                            (list client
                                  (reverse (cons operation asked))))))))))
              (close-port port)
              result))))

       (bind server AF_UNIX file)
       (listen server 1)
       (let* ((thread (call-with-new-thread serve))
              (value  (proc file)))
         (match (join-thread thread (+ (current-time) 60)
                             '(no-client ()))
           ((client asked)
            (close-port server)
            (values value client asked))))))))

(define (use-all-of-goonix file)
  "Open a connection to the daemon at FILE and use on it the setting and each
operation of goonix.  Return, for each of the five uses, 'answered if the
daemon answered it and 'refused if this client raised an error instead."
  (define (use thunk)
    (guard (c ((store-protocol-error? c) 'refused))
      (thunk)
      'answered))

  (let* ((store  (open-connection file))
         (result (list (use (lambda ()
                              (set-build-options store #:deep-scan? #t)))
                       (use (lambda ()
                              (query-realised-output/direct
                               store "/gnu/store/unrealised.drv" "out")))
                       (use (lambda ()
                              (query-build-records store
                                                   (make-bytevector 32 0)
                                                   "out")))
                       (use (lambda ()
                              (query-build-graph
                               store "/gnu/store/unrealised.drv")))
                       (use (lambda ()
                              (query-sessions store))))))
    (close-connection store)
    result))

(define (sent-to-daemon word)
  "Use all of goonix with a daemon that sends WORD in the greeting.  Return
the identifiers of the operations it was sent, the value of the setting
\"goonix-deep-scan\" it was sent or #f, and what became of each use."
  (let-values (((uses client asked)
                (call-with-recording-daemon word use-all-of-goonix)))
    (list (map (match-lambda
                 ((operation . _) operation)
                 (operation operation))
               asked)
          (any (match-lambda
                 ((19 . settings) (assoc-ref settings "goonix-deep-scan"))
                 (_ #f))
               asked)
          uses)))

(define %upstream-conversation
  ;; 'set-options' without the setting of goonix, and nothing else.
  '((19) #f (answered refused refused refused refused)))

(test-equal "a daemon of upstream's version is sent nothing of goonix"
  %upstream-conversation
  (sent-to-daemon %protocol-version))

(test-equal "a daemon of a later version is sent nothing of goonix"
  ;; These are the versions that goonix daemons announced before they gave
  ;; the signal: numbers that upstream may give a meaning of its own.
  (list %upstream-conversation %upstream-conversation %upstream-conversation)
  (map sent-to-daemon '(#x165 #x166 #x167)))

(test-equal "a daemon with another word is sent nothing of goonix"
  ;; Bits above the version that are not the tag.
  %upstream-conversation
  (sent-to-daemon (logior #x00010000 %protocol-version)))

(test-equal "a daemon that gives the signal is sent all of goonix"
  '((19 82 83 84 85) "true" (answered answered answered answered answered))
  (sent-to-daemon (logior %signal %protocol-version)))

(test-equal "the client gives the signal above its protocol version"
  (list %protocol-version %tag #t)
  (let-values (((value client asked)
                (call-with-recording-daemon %protocol-version
                                            (lambda (file)
                                              (close-connection
                                               (open-connection file))))))
    (list (word-version client) (word-tag client)
          (positive? (word-level client)))))

(test-equal "a connection refused an operation of goonix is still served"
  '(refused (19))
  ;; The operation was not sent: the daemon sees the next one in its place.
  (let-values (((value client asked)
                (call-with-recording-daemon
                 %protocol-version
                 (lambda (file)
                   (let* ((store   (open-connection file))
                          (refused (guard (c ((store-protocol-error? c)
                                              'refused))
                                     (query-sessions store)
                                     'answered)))
                     (set-build-options store)
                     (close-connection store)
                     refused)))))
    (list value
          (map (match-lambda
                 ((operation . _) operation)
                 (operation operation))
               asked))))

(test-equal "the publisher has no build graph of a daemon without the signal"
  '(404 0)
  ;; It answers as for a path that it does not serve, and asks the daemon
  ;; nothing: not even whether the derivation is there.
  (let-values (((port written) (open-bytevector-output-port)))
    (let* ((store  (port->connection port))
           (server ((@ (guix scripts publish) open-server-socket)
                    (make-socket-address AF_INET INADDR_LOOPBACK 0)))
           (uri    (string->uri
                    (format #f "http://127.0.0.1:~a/goonix/records/unrealised.drv"
                            (sockaddr:port (getsockname server))))))
      (call-with-new-thread
       (lambda ()
         ((@ (guix scripts publish) run-publish-server) server store)))
      (let loop ((tries 0))
        (match (false-if-exception
                (call-with-values (lambda () (http-get uri)) list))
          ((response body)
           (list (response-code response)
                 (bytevector-length (written))))
          (_
           ;; The server is not listening yet.
           (if (< tries 600)
               (begin
                 (usleep 50000)
                 (loop (+ tries 1)))
               'no-answer)))))))


;;;
;;; What the test suite's daemon answers.
;;;

(define (greet word)
  "Connect to the test suite's daemon and exchange the greeting with it,
sending WORD as the version of this client.  Return the port and the word
that the daemon sent as its version."
  (let ((port (socket PF_UNIX SOCK_STREAM 0)))
    (connect port AF_UNIX (%daemon-socket-uri))
    (write-int %worker-magic-1 port)
    (force-output port)
    (unless (= %worker-magic-2 (read-int port))
      (error "the daemon did not answer the greeting"))
    (let ((daemon (read-int port)))
      (write-int word port)
      (write-int 0 port)                          ;no CPU affinity
      (write-int 1 port)                          ;reserve space
      (force-output port)
      (let loop ()
        (let ((frame (read-int port)))
          (cond ((= frame %stderr-last)
                 (values port daemon))
                ((= frame %stderr-next)
                 (read-maybe-utf8-string port)
                 (loop))
                (else
                 (error "the daemon did not accept the greeting" frame))))))))

(define (asked-without-signal operation)
  "Send OPERATION and nothing after it to the test suite's daemon, on a
connection of a client that gave no signal.  Return what the daemon did:
(error MESSAGE STATUS), (answered), or (ended) if it ended the connection
without a word."
  (let-values (((port daemon) (greet %protocol-version)))
    (write-int operation port)
    (force-output port)
    ;; A daemon that takes OPERATION for one with arguments must not wait
    ;; for them.
    (shutdown port 1)
    (let ((result
           (let loop ()
             (let ((frame (guard (c ((nar-error? c) #f))
                            (read-int port))))
               (cond ((not frame)
                      '(ended))
                     ((= frame %stderr-error)
                      (let* ((message (read-maybe-utf8-string port))
                             (status  (guard (c ((nar-error? c) #f))
                                        (read-int port))))
                        (list 'error message status)))
                     ((= frame %stderr-next)
                      (read-maybe-utf8-string port)
                      (loop))
                     (else
                      '(answered)))))))
      (close-port port)
      result)))

(define (with-number message from to)
  "Return MESSAGE with the number TO where it has the number FROM."
  (let ((from (number->string from)))
    (match (string-contains message from)
      (#f message)
      (index (string-append (string-take message index)
                            (number->string to)
                            (string-drop message
                                         (+ index (string-length from))))))))

(test-equal "the daemon announces the client's version, below the signal"
  (list %protocol-version %tag #t)
  (let-values (((port daemon) (greet %protocol-version)))
    (close-port port)
    (list (word-version daemon) (word-tag daemon)
          (positive? (word-level daemon)))))

(test-assert "the daemon refuses an operation that does not exist"
  (match (asked-without-signal %no-operation)
    (('error (? string? message) (? integer? status))
     (string-contains message (number->string %no-operation)))
    (_ #f)))

(test-equal "a client without the signal is refused the operations of goonix"
  ;; Each as the operation that does not exist: the same message with its
  ;; own number, and the same status.
  (match (asked-without-signal %no-operation)
    (('error message status)
     (map (lambda (operation)
            (list 'error (with-number message %no-operation operation)
                  status))
          %goonix-operations))
    (other other))
  (map asked-without-signal %goonix-operations))

(test-assert "a client without the signal is served upstream's operations"
  ;; This is the connection of a client of upstream: its word has no signal,
  ;; and it reads the daemon's as upstream reads it.
  (let-values (((port daemon) (greet %protocol-version)))
    (let* ((store (port->connection port
                                    #:version (word-version daemon)))
           (item  (begin
                    (set-build-options store)
                    (add-text-to-store store "upstream" (random-text))))
           (valid (valid-path? store item)))
      (close-connection store)
      valid)))

(test-equal "a client with the signal is answered"
  '("1" ())
  (with-store store
    (list (first (query-sessions store))
          (query-build-records store (make-bytevector 32 0) "out"))))

(test-end "goonix-protocol")

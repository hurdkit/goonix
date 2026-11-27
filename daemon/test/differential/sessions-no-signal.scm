;; The second client of sessions.sh: one that gives no goonix signal in its
;; greeting, as a client of upstream.  For such a client the operations of
;; goonix do not exist: the daemon answers operation 85 as it answers an
;; operation that no daemon has, reads nothing after it, and ends the
;; connection.  The greeting and the questions are written here byte by byte.
(use-modules (guix store) (guix remote-procedures) (guix serialization)
             (ice-9 binary-ports) (ice-9 match)
             (srfi srfi-11) (srfi srfi-34))

(define (say . text) (for-each display text) (newline) (force-output))
(define (assert condition . message)
  (unless condition
    (apply say "FAIL: " message)
    (exit 1)))

(define %stderr-next  #x6f6c6d67)
(define %stderr-last  #x616c7473)
(define %stderr-error #x63787470)

(define (greet)
  "Connect to the daemon and exchange the greeting, sending the protocol
version and nothing above it.  Return the port and the word the daemon sent."
  (let ((port (socket PF_UNIX SOCK_STREAM 0)))
    (connect port AF_UNIX (getenv "GUIX_DAEMON_SOCKET"))
    (write-int %worker-magic-1 port)
    (force-output port)
    (assert (= %worker-magic-2 (read-int port))
            "the daemon did not answer the greeting")
    (let ((daemon (read-int port)))
      (write-int %protocol-version port)
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
                 (assert #f "the daemon did not accept the greeting: "
                         (number->string frame 16)))))))))

(define (ask operation)
  "Send OPERATION and nothing after it.  Return (refused MESSAGE STATUS),
(answered) or (ended)."
  (let-values (((port daemon) (greet)))
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
                        (list 'refused message status)))
                     ((= frame %stderr-next)
                      (read-maybe-utf8-string port)
                      (loop))
                     (else
                      '(answered)))))))
      (close-port port)
      result)))

;; The daemon's own word has upstream's version where upstream reads it.
(let-values (((port daemon) (greet)))
  (close-port port)
  (assert (= %protocol-version (logand daemon #xffff))
          "the daemon announces version " (number->string (logand daemon #xffff) 16)
          ", the client has " (number->string %protocol-version 16)))

(match (ask 99)
  (('refused message status)
   (let ((expected (list 'refused
                         (let ((index (string-contains message "99")))
                           (assert index "the refusal of operation 99 does not name it: "
                                   message)
                           (string-append (string-take message index) "85"
                                          (string-drop message (+ index 2))))
                         status))
         (got (ask 85)))
     (assert (equal? got expected)
             "a client that gave no signal asked for the sessions and got "
             got ", not " expected)))
  (other
   (assert #f "the daemon did not refuse operation 99: " other)))
(say "refused as an operation that does not exist")

(define (after-refusal operation)
  "Send OPERATION and nothing after it, and keep this side of the connection
open.  Return 'ended if the daemon refuses it and then ends the connection,
'open if the connection is still there some seconds after the refusal, or
what else happened."
  (let-values (((port daemon) (greet)))
    (write-int operation port)
    (force-output port)
    (let ((result
           (if (= %stderr-error (read-int port))
               (begin
                 (read-maybe-utf8-string port)
                 (read-int port)                  ;status
                 (match (select (list port) '() '() 10)
                   (((_) _ _)
                    (if (eof-object? (get-u8 port)) 'ended 'more-was-sent))
                   (_ 'open)))
               'not-refused)))
      (close-port port)
      result)))

;; A daemon that refused an operation read nothing of it; what the client
;; sends next could be the rest of it.  Upstream's daemon ends the connection.
(let ((ends (map after-refusal '(99 85))))
  (assert (equal? ends '(ended ended))
          "after refusing operations 99 and 85 the connection is " ends
          ", not ended"))
(say "the connection ended after each refusal")

;; The same client is served what upstream has.
(let-values (((port daemon) (greet)))
  (let ((store (port->connection port #:version (logand daemon #xffff))))
    (assert (valid-path? store (add-text-to-store store "no-signal" "served"))
            "a client that gave no signal was not served")
    (close-connection store)))
(say "served upstream's operations")

;; The client of sessions.sh.  It holds three connections: one builds, with a
;; builder that waits to be let go, one stays idle, and one asks the daemon
;; for its sessions with operation 85, written here byte by byte so that the
;; test does not depend on a client that knows the operation.
;;
;; SESSIONS_EXPECT says what the daemon under test does with the question:
;; `report' (the Haskell daemon answers) or `refusal' (the C++ daemon does not
;; know the operation).
(use-modules (guix store) (guix serialization) (guix derivations) (guix tests)
             (gnu packages bootstrap)
             (ice-9 binary-ports) (ice-9 match) (ice-9 textual-ports)
             (ice-9 threads)
             (srfi srfi-1) (srfi srfi-11) (srfi srfi-34))

(define fixture (getenv "SESSIONS_FIXTURE"))
(define expect (string->symbol (getenv "SESSIONS_EXPECT")))
(define daemon-pid (string->number (getenv "SESSIONS_DAEMON_PID")))
(define (in-fixture name) (string-append fixture "/" name))
(define (say . text) (for-each display text) (newline) (force-output))
(define (touch file) (call-with-output-file file (const #t)))
(define (assert condition . message)
  (unless condition
    (apply say "FAIL: " message)
    (exit 1)))

(define (connect)
  (let ((store (open-connection (getenv "GUIX_DAEMON_SOCKET"))))
    (set-build-options store #:use-substitutes? #f #:offload? #f)
    store))

(define %stderr-next  #x6f6c6d67)
(define %stderr-last  #x616c7473)
(define %stderr-error #x63787470)

(define (ask store)
  "Send operation 85 on STORE.  Return (answer STRINGS) or (refused MESSAGE)."
  (let ((port (store-connection-socket store)))
    (write-int 85 port)
    (force-output port)
    (let loop ()
      (let ((frame (read-int port)))
        (cond ((= frame %stderr-last)
               (list 'answer (read-string-list port)))
              ((= frame %stderr-error)
               (let* ((message (read-maybe-utf8-string port))
                      (status  (read-int port)))
                 (list 'refused message)))
              ((= frame %stderr-next)
               (read-maybe-utf8-string port)
               (loop))
              (else
               (assert #f "unexpected frame " (number->string frame 16))))))))

(define (leave store)
  "End STORE's connection and return once the daemon has ended it too."
  (let ((port (store-connection-socket store)))
    (force-output port)
    (shutdown port 1)
    (let loop ()
      (unless (eof-object? (get-u8 port))
        (loop)))
    (close-port port)))

(define (closed? store)
  "Return true if the daemon has ended STORE's connection."
  (guard (c ((nar-error? c) #t))
    (catch 'system-error
      (lambda ()
        (eof-object? (lookahead-u8 (store-connection-socket store))))
      (const #t))))

(define (rows strings)
  "Return the sessions STRINGS, an answer without its two leading strings,
denotes: a list of (NUMBER CLIENT LOCKS CHILDREN)."
  (let loop ((strings strings) (result '()))
    (match strings
      (() (reverse result))
      ((number client count rest ...)
       (let*-values (((locks rest) (split-at rest (string->number count)))
                     ((children rest) (split-at (cdr rest)
                                                (string->number (car rest)))))
         (loop rest
               (cons (list (string->number number) (string->number client)
                           locks (map string->number children))
                     result)))))))

(define (report store)
  "Ask on STORE and return the daemon's sessions; fail on anything else."
  (match (ask store)
    (('answer (version pid strings ...))
     (assert (string=? version "1") "the answer has version " version)
     (assert (eqv? (string->number pid) daemon-pid)
             "the answer names daemon " pid ", not " daemon-pid)
     (rows strings))
    (other
     (assert #f "the daemon did not report its sessions: " other))))

(define (process-field pid name)
  (call-with-input-file (format #f "/proc/~a/status" pid)
    (lambda (port)
      (let loop ()
        (let ((line (get-line port)))
          (cond ((eof-object? line) #f)
                ((string-prefix? name line)
                 (string-trim-both (string-drop line (string-length name))))
                (else (loop))))))))

(define (command-line-of pid)
  (call-with-input-file (format #f "/proc/~a/cmdline" pid) get-string-all))

(%graft? #f)
(define building (connect))
(define idle (connect))
(define shell (add-to-store building "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))
(define script
  (add-text-to-store building "sessions-builder.sh"
    (string-append
     ": > '" (in-fixture "builder-started") "'\n"
     "while ! test -e '" (in-fixture "builder-may-finish") "'; do\n"
     "  read -t 1 _ < '" (in-fixture "tick") "' || true\n"
     "done\n"
     "printf done > \"$out\"\n")))
(define drv
  (derivation building "sessions" shell (list "-e" script)
              #:sources (list shell script)))
(define out (derivation->output-path drv))
(define build
  (call-with-new-thread
   (lambda ()
     (guard (c (#t (list 'raised c)))
       (build-derivations building (list drv))
       'returned))))
(let loop ((tries 0))
  (unless (file-exists? (in-fixture "builder-started"))
    (assert (< tries 1200) "the builder did not start")
    (usleep 50000)
    (loop (+ tries 1))))

(define asking (connect))
(case expect
  ((report)
   (let ((sessions (report asking)))
     ;; The building and the idle connection, not the asking one.
     (assert (= 2 (length sessions))
             "sessions reported while three connections are open: " sessions)
     (assert (every (match-lambda ((_ client _ _) (eqv? client (getpid))))
                    sessions)
             "a session's client is not this process: " sessions)
     (assert (apply < (map first sessions))
             "the session numbers do not tell the sessions apart: " sessions)
     (match sessions
       (((_ _ locks children) (_ _ idle-locks idle-children))
        (assert (equal? locks (list (string-append out ".lock")))
                "the building session's locks: " locks)
        (assert (and (null? idle-locks) (null? idle-children))
                "the idle session holds " idle-locks " " idle-children)
        (match children
          ((child)
           (assert (equal? (process-field child "PPid:")
                           (number->string daemon-pid))
                   "child " child " is not a child of the daemon")
           (assert (string-contains (command-line-of child) script)
                   "child " child " does not run the builder"))
          (_ (assert #f "the building session's children: " children)))))
     ;; The connection that asked is still served.
     (assert (equal? sessions (report asking))
             "a second answer on the same connection differs"))
   (say "sessions reported while a build runs"))
  ((refusal)
   (match (ask asking)
     (('refused message)
      (assert (string-contains message "invalid operation 85")
              "the refusal says: " message))
     (other
      (assert #f "the daemon did not refuse operation 85: " other)))
   (assert (closed? asking)
           "the daemon kept the connection that asked for operation 85")
   (say "operation 85 refused, its connection ended")))

;; Whatever the daemon did with the question, its other clients are served.
(assert (not (valid-path? idle out)) "the output is valid before its build ended")
(touch (in-fixture "builder-may-finish"))
(assert (eq? 'returned (join-thread build)) "build-derivations did not return")
(assert (valid-path? building out) "the output is not valid after its build")
(define later (connect))
(assert (valid-path? later out) "a connection opened afterwards sees no output")
(say "the other connections were served")

(when (eq? expect 'report)
  (match (report later)
    (((_ _ () ()) (_ _ () ()) (_ _ () ()))
     #t)
    (sessions
     (assert #f "sessions after the build, with four connections open: "
             sessions)))
  ;; A connection that the daemon has ended is not reported any more, from
  ;; the moment its client can know.  `guix processes' counts on that for
  ;; the connection it asks on.
  (leave idle)
  (leave asking)
  (match (report later)
    (((_ _ () ()))
     #t)
    (sessions
     (assert #f "sessions after the daemon ended two connections: " sessions)))
  (let loop ((times 0))
    (when (< times 50)
      (leave (connect))
      (match (report later)
        (((_ _ () ()))
         (loop (+ times 1)))
        (sessions
         (assert #f "a connection the daemon has ended is reported: "
                 sessions)))))
  (say "sessions reported after the build and after two clients left"))
(close-connection building)
(close-connection later)
(say "client done")

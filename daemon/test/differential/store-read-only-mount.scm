;; The client and the socket activation of store-read-only-mount.sh.
;;
;;   activate SOCKET DAEMON ARG...  listen on SOCKET, then execute DAEMON as
;;                                  systemd starts a socket-activated daemon:
;;                                  the socket as file descriptor 3,
;;                                  LISTEN_FDS=1 and LISTEN_PID its PID.
;;   serve SOCKET NONCE             add a text to the store and build a
;;                                  derivation whose builder writes its
;;                                  output; both must be served.
;;   refused SOCKET                 connect and add a text; print whether
;;                                  that was served, refused (with the
;;                                  daemon's message) or not answered.
;;   bootstrap                      print the file of the bootstrap bash that
;;                                  'serve' builds with; (guix tests) keeps
;;                                  it in the tree once it has downloaded it
;;                                  through the daemon of GUIX_DAEMON_SOCKET.
(use-modules (guix store) (guix derivations) (guix utils) (guix tests)
             ((guix build utils) #:select (mkdir-p))
             (ice-9 match) (ice-9 textual-ports)
             (srfi srfi-34))

(define (activate socket-file program arguments)
  (let ((listener (socket PF_UNIX SOCK_STREAM 0)))
    (mkdir-p (dirname socket-file))
    (when (file-exists? socket-file)
      (delete-file socket-file))
    (bind listener AF_UNIX socket-file)
    (listen listener 64)
    (dup2 (fileno listener) 3)
    (fcntl 3 F_SETFD 0)
    (setenv "LISTEN_FDS" "1")
    (setenv "LISTEN_PID" (number->string (getpid)))
    (apply execl program program arguments)))

(define (assert condition message)
  (unless condition (error message)))

(define (contents file)
  (call-with-input-file file get-string-all))

(define (serve socket-file nonce)
  (let ((store (open-connection socket-file)))
    (set-build-options store #:use-substitutes? #f #:offload? #f)
    ;; The daemon itself writes to the store.
    (let* ((text (string-append "written by the daemon " nonce "\n"))
           (item (add-text-to-store store "read-only-mount-text" text)))
      (assert (string=? (contents item) text) "the text item differs")
      (format #t "added ~a~%" item))
    ;; A builder that the daemon starts writes its output to the store.
    (let* ((bash (add-to-store store "bash" #t "sha256"
                               (search-bootstrap-binary "bash"
                                                        (%current-system))))
           (drv (derivation store "read-only-mount-build" bash
                            (list "-c" (string-append "echo built " nonce
                                                      " > $out"))
                            #:sources (list bash)))
           (out (derivation->output-path drv)))
      (build-derivations store (list drv))
      (assert (string=? (contents out) (string-append "built " nonce "\n"))
              "the build output differs")
      (format #t "built ~a~%" out))
    (close-connection store)
    (format #t "store-read-only-mount client: served~%")))

(define (refused socket-file)
  (define (no-answer . details)
    (format #t "no answer: ~s~%" details))
  (catch #t
    (lambda ()
      (guard (condition
              ((store-protocol-error? condition)
               (format #t "refused: ~a~%"
                       (store-protocol-error-message condition)))
              ((store-connection-error? condition)
               (no-answer (strerror (store-connection-error-code condition)))))
        (let ((store (open-connection socket-file)))
          (add-text-to-store store "read-only-mount-refused" "served\n")
          (close-connection store)
          (format #t "served~%"))))
    no-answer))

(match (cdr (command-line))
  (("activate" socket-file program arguments ...)
   (activate socket-file program arguments))
  (("serve" socket-file nonce)
   (serve socket-file nonce))
  (("refused" socket-file)
   (refused socket-file))
  (("bootstrap")
   (format #t "~a~%" (search-bootstrap-binary "bash" (%current-system)))))

;;; goonix: publish signed build records through HTTP.
(define-module (test-ca-publish-records)
  #:use-module (guix scripts publish)
  #:use-module (guix ca records)
  #:use-module (guix tests)
  #:use-module (guix store)
  #:use-module (guix derivations)
  #:use-module (guix packages)
  #:use-module (gnu packages bootstrap)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-64))

(unsetenv "http_proxy")
(define %store (open-connection-for-tests))

(define (http-get-body uri)
  (call-with-values (lambda () (http-get uri))
    (lambda (response body) body)))

(define publish-port
  (let ((socket (socket PF_INET SOCK_STREAM 0)))
    (setsockopt socket SOL_SOCKET SO_REUSEADDR 1)
    (bind socket (make-socket-address AF_INET INADDR_LOOPBACK 0))
    (let ((port (sockaddr:port (getsockname socket))))
      (close-port socket)
      port)))
(define (publish-uri route)
  (format #f "http://127.0.0.1:~a~a" publish-port route))

(define (wait-for-publish-test-server port)
  (let ((conn (socket PF_INET SOCK_STREAM 0)))
    (dynamic-wind
      (const #t)
      (lambda ()
        (let loop ((remaining 1000))
          (unless (false-if-exception
                   (connect conn AF_INET
                            (inet-pton AF_INET "127.0.0.1") port))
            (when (zero? remaining)
              (error "test publisher did not start" port))
            (usleep 10000)
            (loop (- remaining 1)))))
      (lambda () (close-port conn)))))

;; This publisher belongs to this test file and can run alone.
(define publish-pid
  (let ((pid (primitive-fork)))
    (if (zero? pid)
        (begin
          (guix-publish "--listen=127.0.0.1"
                        (format #f "--port=~a" publish-port) "-C0")
          (primitive-exit 0))
        pid)))
(wait-for-publish-test-server publish-port)

(define %ca-derivation
  (let* ((guile-drv (package-derivation %store %bootstrap-guile))
         (guile (string-append (derivation->output-path guile-drv)
                               "/bin/guile")))
    (derivation %store "publish-ca" guile
                '("--no-auto-compile" "-c"
                  "(call-with-output-file (getenv \"out\") (lambda (p) (display \"published\" p)))")
                #:inputs (list (derivation-input guile-drv))
                #:addressing 'content)))

(build-derivations %store (list %ca-derivation))
(define %ca-output
  (realised-output-path %store %ca-derivation "out"))
(define %ca-record
  (build-graph-records %store (derivation-file-name %ca-derivation)))

(define %ca-record-expression
  (call-with-input-string
      (http-get-body
       (publish-uri (string-append "/goonix/records/"
                                   (basename
                                    (derivation-file-name %ca-derivation)))))
    read))

(test-begin "publish")

(test-equal "/goonix/records/DERIVATION serves the signed graph"
  %ca-record
  (expression->build-records %ca-record-expression))

(test-assert "/goonix/records/DERIVATION serves unsigned choice hints"
  (equal? (list (list (derivation-file-name %ca-derivation) "out"
                      (realised-output-path %store %ca-derivation "out")))
          (expression->graph-choices %ca-record-expression)))

;; A malformed record has its own refusal.  An unrelated renderer failure is
;; not a record error and must not become a quiet 422.  Exercise the actual
;; HTTP server: a private renderer binding may be absent from compiled Guile
;; modules, and a cross-thread mock would not reach the server.
(define (publish-test-port)
  (let ((socket (socket PF_INET SOCK_STREAM 0)))
    (setsockopt socket SOL_SOCKET SO_REUSEADDR 1)
    (bind socket (make-socket-address AF_INET INADDR_LOOPBACK 0))
    (let ((port (sockaddr:port (getsockname socket))))
      (close-port socket)
      port)))

(define (publish-http-error-response failure)
  "Run a publisher whose graph transport raises FAILURE.  Return the record
response code followed by the next request's code, proving server survival."
  (let* ((store (open-connection-for-tests))
         (drv (derivation store "publish-narrow-catch" "/bin/sh" '()
                          #:addressing 'input))
         (name (basename (derivation-file-name drv)))
         (port (publish-test-port))
         (pid (primitive-fork)))
    (if (zero? pid)
        (dynamic-wind
          (lambda ()
            ;; Patch the exported transport before loading the publisher in
            ;; this isolated child.  The parent and its daemon are untouched.
            (module-set! (resolve-module '(guix ca records))
                         'build-graph-expression
                         (lambda (store derivation) (throw failure "boom"))))
          (lambda ()
            (guix-publish "--listen=127.0.0.1"
                          (format #f "--port=~a" port) "-C0")
            (primitive-exit 0))
          (lambda () (primitive-exit 1)))
        (dynamic-wind
          (const #t)
          (lambda ()
            (wait-for-publish-test-server port)
            (map (lambda (route)
                   (response-code
                    (http-get
                     (string-append "http://127.0.0.1:"
                                    (number->string port) route))))
                 (list (string-append "/goonix/records/" name)
                       "/nix-cache-info")))
          (lambda ()
            (kill pid SIGTERM)
            (waitpid pid))))))

(test-equal "publish refuses an invalid record and answers the next request"
  '(422 200)
  (publish-http-error-response 'goonix-invalid-signature-encoding))

(test-equal "publish does not turn an unrelated graph failure into a 422"
  '(500 200)
  (publish-http-error-response 'unrelated-test-error))

(test-end "publish")

(dynamic-wind
  (const #t)
  (lambda () (close-connection %store))
  (lambda ()
    (kill publish-pid SIGTERM)
    (waitpid publish-pid)))

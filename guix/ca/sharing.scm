;;; goonix: asynchronous graph-agent transport.  Authentication stays in the daemon.
(define-module (guix ca sharing)
  #:use-module (guix base16)
  #:use-module (guix ca records)
  #:use-module ((guix build download) #:select (resolve-uri-reference))
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-34)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (ice-9 match)
  #:use-module (rnrs io ports)
  #:export (run-graph-loop))

(define %maximum-graph-expression-size (* 64 1024 1024))

(define (graph-uri cache derivation)
  (resolve-uri-reference
   (build-relative-ref #:path (string-append "goonix/records/"
                                             (basename derivation)))
   (string->uri (if (string-suffix? "/" cache)
                    cache (string-append cache "/")))))

(define (read-cache-graph cache derivation open-connection timeout)
  (catch #t
    (lambda ()
      (let* ((uri (graph-uri cache derivation))
             (port (open-connection uri #:fresh? #t #:timeout timeout)))
        (dynamic-wind
          (const #t)
          (lambda ()
            (call-with-values
                (lambda ()
                  (http-get uri #:port port #:streaming? #t
                            #:decode-body? #t))
              (lambda (response body)
                (and (= 200 (response-code response))
                     (let ((length (response-content-length response)))
                       (when (and length
                                  (> length %maximum-graph-expression-size))
                         (error "goonix graph response is too large"))
                       (read-graph-expression
                        body %maximum-graph-expression-size))))))
          (lambda () (false-if-exception (close-port port))))))
    (lambda (key . arguments)
      (format (current-error-port)
              "could not fetch goonix records from '~a': ~a ~s~%"
              cache key arguments)
      #f)))

(define (run-graph-loop port caches open-connection timeout)
  (let loop ()
    (match (read-line)
      ((? eof-object?) #t)
      ((= string-tokenize ("records" derivation cache))
       (guard (c (#t
                  (format (current-error-port)
                          "goonix graph query failed: ~s~%" c)
                  (display "goonix-records 1\n0\n0\n" port)
                  (force-output port)))
         (let ((expression (read-cache-graph cache derivation
                                             open-connection timeout)))
           (if expression
               (write-graph-fields port (expression->build-records expression)
                                   (expression->graph-choices expression))
               (display "goonix-records 1\n0\n0\n" port))
           (force-output port)))
       (loop))
      (_ (loop)))))

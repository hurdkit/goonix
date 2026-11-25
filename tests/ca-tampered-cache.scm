;;; goonix: test-only cache that alters a signed record without re-signing it.
(use-modules (guix store) (guix ca) (guix ca records)
             (ice-9 match) (web server) (web request) (web response)
             (web uri) (rnrs io ports))

(define store (open-connection))
(define (handler request body)
  (let ((path (uri-path (request-uri request))))
    (format (current-error-port) "GET ~a~%" path)
    (force-output (current-error-port))
    (match (string-split path #\/)
      (("" "goonix" "records" name)
       (call-with-values
           (lambda () (graph-response store
                         (string-append (%store-prefix) "/" name)))
         (lambda (records hints)
           (let ((tampered
                  (map (lambda (record)
                         (match record
                           ((hash derivation output path origin checked signature)
                            (list hash derivation output
                                  (string-append path "-tampered")
                                  origin checked signature))))
                       records)))
             (values '((content-type . (text/plain)))
                     (call-with-output-string
                       (lambda (port)
                         (write (append (build-records->expression tampered)
                                        `((choices ,hints))) port)
                         (newline port))))))))
      (_ (values (build-response #:code 404) "")))))
(run-server handler 'http `(#:host "127.0.0.1"
                            #:port ,(string->number (getenv "GOONIX_TAMPER_PORT"))))

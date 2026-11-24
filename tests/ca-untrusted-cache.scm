;;; goonix: test-only cache that re-signs graph records with an untrusted key.
(use-modules (guix store) (guix ca) (guix ca records) (guix pki)
             (gcrypt pk-crypto) (gcrypt hash) (ice-9 match)
             (ice-9 rdelim) (rnrs io ports) (web server) (web request)
             (web response) (web uri) (srfi srfi-1))

(define store (open-connection))
(define private-key
  (read-file-sexp (string-append (getenv "GUIX_CONFIGURATION_DIRECTORY")
                                 "/signing-key.sec")))
(define public-key
  (read-file-sexp (string-append (getenv "GUIX_CONFIGURATION_DIRECTORY")
                                 "/signing-key.pub")))
(define (signature record)
  (match record
    ((hash derivation output path origin checked _)
     (let* ((bytes (canonical-build-record-payload
                    hash derivation output path origin
                    #:relocation-checked? (string=? checked "1")))
            (data (bytevector->hash-data (sha256 bytes)
                                         #:key-type (key-type public-key))))
       (canonical-sexp->string (signature-sexp data private-key public-key))))))
(define (untrusted-expression derivation)
  (call-with-values (lambda () (graph-response store derivation))
    (lambda (records hints)
      (append (build-records->expression
               (map (lambda (record)
                      (append (take record 6) (list (signature record))))
                    records))
              `((choices ,hints))))))
(define (handler request body)
  (let ((path (uri-path (request-uri request))))
    (format (current-error-port) "GET ~a~%" path)
    (force-output (current-error-port))
    (match (string-split path #\/)
      (("" "goonix" "records" name)
       (values '((content-type . (text/plain)))
               (call-with-output-string
                 (lambda (port)
                   (write (untrusted-expression
                           (string-append (%store-prefix) "/" name)) port)
                   (newline port)))))
      (_ (values (build-response #:code 404) "")))))
(run-server handler 'http `(#:host "127.0.0.1"
                             #:port ,(string->number (getenv "GOONIX_BAD_PORT"))))

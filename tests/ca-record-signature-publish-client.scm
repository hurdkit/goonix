;;; goonix: verify that the publisher returns the exact stored signature bytes.
;;; The expected value is hexadecimal, so no raw legacy bytes enter a UTF-8
;;; Scheme reader.  The publisher must carry them as base64.
(use-modules (guix ca records) (guix base16) (guix base64)
             (rnrs bytevectors) (rnrs io ports))

(define response
  (call-with-input-file (getenv "GOONIX_RESPONSE")
    (lambda (port)
      (set-port-encoding! port "ISO-8859-1")
      (read port))))
(let* ((records (expression->build-records response))
       (signature (list-ref (car records) 6))
       (expected (base16-string->bytevector (getenv "GOONIX_EXPECTED_HEX"))))
  (unless (equal? expected (base64-decode signature))
    (error "the publisher did not preserve the signature bytes")))

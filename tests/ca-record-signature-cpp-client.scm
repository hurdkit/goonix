;;; goonix: a real C++-signed high-byte signature must survive the Scheme
;;; base64 boundary and remain valid to guix authenticate.
(use-modules (guix base16) (guix base64) (guix ca records)
             (ice-9 popen) (ice-9 rdelim) (rnrs bytevectors)
             (ice-9 binary-ports)
             (ice-9 iconv))
(define encoded (call-with-input-file (getenv "GOONIX_CPP_SIGNATURE") read-line))
(define expected (base16-string->bytevector
                  (call-with-input-file (getenv "GOONIX_CPP_SIGNATURE")
                    (lambda (p) (read-line p) (read-line p)))))
(unless (equal? expected (base64-decode encoded))
  (error "C++ signature bytes were changed by the Scheme boundary"))
(define decoded (decode-signature encoded))
(define expected-hash
  (call-with-input-file (getenv "GOONIX_CPP_SIGNATURE")
    (lambda (p) (read-line p) (read-line p) (read-line p))))
(unless (equal? expected (string->bytevector decoded "ISO-8859-1"))
  (error "decode-signature did not return the signer's bytes"))
;; Verify through the real authenticator, with the same ACL as the daemon.
;; Its response is CODE SPACE LENGTH:BYTES, not a text line: the decoded
;; payload may contain high bytes.  Read that protocol explicitly.
(let* ((port (open-pipe* OPEN_BOTH "guix" "authenticate"))
       (bytes (string->bytevector decoded "ISO-8859-1")))
  (format port "verify ~a:" (bytevector-length bytes))
  (put-bytevector port bytes)
  (newline port)
  (force-output port)
  (let* ((code (read-delimited " " port))
         (length (string->number (read-delimited ":" port)))
         (reply (get-bytevector-n port length)))
    (unless (and (string=? code "0")
                 (string=? expected-hash
                           (bytevector->string reply "ISO-8859-1")))
      (error "guix authenticate rejected or changed the signed payload"
             code (and (bytevector? reply)
                       (bytevector->string reply "ISO-8859-1")))))
  (close-pipe port))
(display "REAL_CPP_HIGH_BYTE_SIGNATURE_PASS\n")

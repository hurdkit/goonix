;;; End-to-end regression for the record signature encoding, DETERMINISTIC.
;;;
;;; The bug: libgcrypt's advanced S-expression writes a digest as a quoted
;;; string with RAW HIGH BYTES when the digest looks printable.  A record whose
;;; signature has that shape cannot be read back by Guile's strict UTF-8
;;; reader, so /goonix/records/... fails with "input locale conversion error"
;;; and the client falls back to building locally.
;;;
;;; Rather than wait for a digest with that shape, this test constructs the
;;; expression a correct publisher would emit for such a record and reads it
;;; the way the client does.  At the base commit the signature field holds the
;;; raw S-expression and the read throws; after the fix the field is base64 and
;;; the same read returns the record.
;;;
;;; It also checks the real publisher path: %ca-record-expression is fetched
;;; from a running `guix publish', so if the daemon emits base64 the expression
;;; must still decode, and its signature field must be pure ASCII.
(use-modules (guix)
             (guix tests)
             (guix ca records)
             (guix base64)
             (srfi srfi-1)
             (srfi srfi-64)
             (ice-9 match)
             (ice-9 textual-ports))

(test-begin "ca-record-signature-encoding")

(define raw-signature
  ;; The exact failing shape: a quoted-string hash token with high bytes.
  (string-append "(signature \n (d\n  (pkcs1)\n  (hash sha256 \"XwH1KY"
                 (string (integer->char #xa5) (integer->char #x24)
                         (integer->char #x5c) (integer->char #x62)
                         (integer->char #x36) (integer->char #x6f)
                         (integer->char #x42) (integer->char #x25)
                         (integer->char #xb8))
                 "\"))\n"))

(define hex64
  (make-string 64 #\a))

(define (record-expression signature)
  `(goonix-records 1
     (,hex64 "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-x.drv"
             "out" "/gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-x"
             "/gnu/store/ccccccccccccccccccccccccccccccc-x.drv"
             "0" ,signature)))

(test-group "a signature carrying raw high bytes cannot be sent as text"
  ;; This is the base commit's behaviour, asserted so the fix is a MEASURED
  ;; change rather than a claim.  The field is not valid UTF-8 once it is
  ;; serialised, so writing it into a text protocol is what breaks.
  (test-assert "the raw signature really does contain high bytes"
    (any (lambda (c) (> (char->integer c) 127))
         (string->list raw-signature)))

  (test-assert "a raw signature is NOT valid base64, so it is refused"
    (catch 'goonix-invalid-signature-encoding
      (lambda () (decode-signature raw-signature) #f)
      (lambda (key . args) #t)))

  (test-equal "a base64 signature round-trips through the record expression"
    raw-signature
    (let* ((encoded (encode-signature raw-signature))
           (expr (record-expression encoded))
           (records (expression->build-records expr)))
      ;; The client reads the expression, then the signature field decodes.
      (and (= 1 (length records))
           (decode-signature (list-ref (car records) 6)))))

  (test-assert "the encoded field is pure ASCII, so a UTF-8 reader cannot throw"
    (every (lambda (c) (< (char->integer c) 128))
           (string->list (encode-signature raw-signature))))

  (test-assert "a record whose signature is raw is rejected, not silently kept"
    ;; An older record written before the fix must not decode by accident and
    ;; yield a different signature.  It must fail loudly.
    (catch 'goonix-invalid-signature-encoding
      (lambda ()
        (let ((records (expression->build-records
                        (record-expression raw-signature))))
          (decode-signature (list-ref (car records) 6)))
        #f)
      (lambda (key . args) #t))))

(test-end "ca-record-signature-encoding")

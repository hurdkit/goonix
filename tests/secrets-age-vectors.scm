;;; goonix: published C2SP/CCTV age vectors for the supported vault subset.
(use-modules (guix secrets age) (gcrypt base16) (gcrypt hash)
             (rnrs bytevectors) (ice-9 binary-ports) (ice-9 iconv)
             (srfi srfi-1) (srfi srfi-64) (zlib) (ice-9 ftw))

(define (fixture-root)
  (or (getenv "GOONIX_AGE_VECTORS") "tests/fixtures/age"))
(define (slice bv start)
  (let ((r (make-bytevector (- (bytevector-length bv) start))))
    (let loop ((i start))
      (when (< i (bytevector-length bv))
        (bytevector-u8-set! r (- i start) (bytevector-u8-ref bv i))
        (loop (+ i 1)))) r))
(define (metadata-line line)
  (let ((i (string-index line #\:)))
    (unless i (error "invalid age fixture metadata" line))
    (cons (substring line 0 i) (substring line (+ i 2)))))
(define (read-vector name)
  (let* ((bytes (call-with-input-file (string-append (fixture-root) "/" name)
                  get-bytevector-all))
         (lines (string-split (bytevector->string bytes "ISO-8859-1") #\newline))
         (meta (take-while (lambda (l) (not (string-null? l))) lines))
         (start (+ 1 (apply + (map (lambda (l) (+ 1 (string-length l))) meta))))
         (cipher (slice bytes start))
         (meta (map metadata-line meta)))
    (values meta
            (if (assoc-ref meta "compressed")
                (call-with-zlib-input-port (open-bytevector-input-port cipher)
                  get-bytevector-all)
                cipher))))

(test-begin "secrets-age-published-vectors")
(define all-fixtures
  (sort (scandir (fixture-root)
                 (lambda (name)
                   (and (not (member name '("." ".." "README")))
                        (not (file-is-directory? (string-append (fixture-root) "/" name))))))
        string<?))
;; The vault subset is X25519, ssh-ed25519 and read-only scrypt. Hybrid
;; ML-KEM/X25519 recipients are deliberately outside that subset.
(define excluded-hybrid
  (filter (lambda (name) (or (string-prefix? "hybrid" name)
                             (string=? name "armor_hybrid"))) all-fixtures))
(define tested-fixtures (lset-difference string=? all-fixtures excluded-hybrid))
(test-equal "every vector is tested or explicitly excluded as hybrid"
  all-fixtures (sort (append tested-fixtures excluded-hybrid) string<?))
(test-assert "the hybrid exclusions are present"
  (and (member "hybrid" excluded-hybrid)
       (member "armor_hybrid" excluded-hybrid)))
(for-each
 (lambda (name)
   (call-with-values (lambda () (read-vector name))
     (lambda (meta cipher)
       (let ((expected (assoc-ref meta "expect"))
             (ids (map cdr (filter (lambda (x) (string=? (car x) "identity")) meta)))
             (passphrase (assoc-ref meta "passphrase")))
         (if (string=? expected "success")
             (test-equal (string-append name " decrypts and hashes correctly")
               (base16-string->bytevector (assoc-ref meta "payload"))
               (bytevector-hash
                (decrypt-age-file cipher
                                  (if passphrase `((scrypt . ,passphrase)) ids))
                (hash-algorithm sha256)))
             (test-error (string-append name " is refused: " expected) #t
               (decrypt-age-file cipher
                                 (if passphrase `((scrypt . ,passphrase)) ids))))))))
 tested-fixtures)
(test-end)

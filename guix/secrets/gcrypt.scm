;;; goonix: small libgcrypt bindings needed by age. No cryptographic
;;; constructions live here; guile-gcrypt supplies hashes, MACs and randomness.
(define-module (guix secrets gcrypt)
  #:use-module (gcrypt internal)
  #:use-module (system foreign)
  #:use-module (rnrs bytevectors)
  #:use-module (gcrypt hash)
  #:use-module (srfi srfi-1)
  #:export (x25519
            x25519-public-key
            chacha20-poly1305-seal
            chacha20-poly1305-open
            scrypt-key
            ed25519-public->x25519
            ed25519-seed->x25519))

(define (foreign-procedure return name parameters)
  (libgcrypt->procedure return name parameters))

(define (pointer-slot)
  (bytevector->pointer (make-bytevector (sizeof '*))))

(define (check who status)
  (unless (zero? status)
    (error (string-append "libgcrypt " who " failed") status)))

(define cipher-open
  (foreign-procedure int "gcry_cipher_open" (list '* int int unsigned-int)))
(define cipher-close
  (foreign-procedure void "gcry_cipher_close" (list '*)))
(define cipher-setkey
  (foreign-procedure int "gcry_cipher_setkey" (list '* '* size_t)))
(define cipher-setiv
  (foreign-procedure int "gcry_cipher_setiv" (list '* '* size_t)))
(define cipher-encrypt
  (foreign-procedure int "gcry_cipher_encrypt"
                     (list '* '* size_t '* size_t)))
(define cipher-decrypt
  (foreign-procedure int "gcry_cipher_decrypt"
                     (list '* '* size_t '* size_t)))
(define cipher-gettag
  (foreign-procedure int "gcry_cipher_gettag" (list '* '* size_t)))
(define cipher-checktag
  (foreign-procedure int "gcry_cipher_checktag" (list '* '* size_t)))

(define cipher-authenticate
  (foreign-procedure int "gcry_cipher_authenticate" (list '* '* size_t)))

(define (bv-pointer bv)
  (if (zero? (bytevector-length bv)) %null-pointer (bytevector->pointer bv)))

(define (with-cipher key nonce aad operation)
  (let ((slot (pointer-slot)))
    (check "cipher open" (cipher-open slot 316 10 0)) ; CHACHA20, POLY1305
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let ((handle (dereference-pointer slot)))
          (check "cipher key" (cipher-setkey handle (bv-pointer key)
                                             (bytevector-length key)))
          (check "cipher nonce" (cipher-setiv handle (bv-pointer nonce)
                                              (bytevector-length nonce)))
          (check "cipher associated data"
                 (cipher-authenticate handle (bv-pointer aad)
                                      (bytevector-length aad)))
          (operation handle)))
      (lambda () (cipher-close (dereference-pointer slot))))))

(define* (chacha20-poly1305-seal key nonce plaintext #:optional (aad #vu8()))
  "Return ciphertext followed by its 16-byte authentication tag."
  (with-cipher key nonce aad
    (lambda (handle)
      (let* ((n (bytevector-length plaintext))
             (result (make-bytevector (+ n 16))))
        (check "cipher encrypt"
               (cipher-encrypt handle (bv-pointer result) n
                               (bv-pointer plaintext) n))
        (check "cipher tag"
               (cipher-gettag handle (bytevector->pointer result n) 16))
        result))))

(define* (chacha20-poly1305-open key nonce ciphertext #:optional (aad #vu8()))
  "Authenticate and decrypt CIPHERTEXT. Never return unauthenticated data."
  (if (< (bytevector-length ciphertext) 16)
      (error "age ciphertext is shorter than its authentication tag")
      (with-cipher key nonce aad
        (lambda (handle)
          (let* ((n (- (bytevector-length ciphertext) 16))
                 (result (make-bytevector n)))
            (check "cipher decrypt"
                   (cipher-decrypt handle (bv-pointer result) n
                                   (bv-pointer ciphertext) n))
            (unless (zero? (cipher-checktag handle
                                            (bytevector->pointer ciphertext n)
                                            16))
              (error "age authentication failed"))
            result)))))

(define kdf-derive
  (foreign-procedure int "gcry_kdf_derive"
                     (list '* size_t int int '* size_t unsigned-long
                           size_t '*)))

(define (scrypt-key passphrase salt log-work-factor)
  "Derive a 32-byte key using age's fixed r=8, p=1 scrypt parameters."
  (unless (and (integer? log-work-factor) (<= 1 log-work-factor 22))
    (error "age scrypt work factor is outside the permitted range"))
  (let ((out (make-bytevector 32)))
    (check "scrypt"
           (kdf-derive (bv-pointer passphrase) (bytevector-length passphrase)
                       48 (ash 1 log-work-factor) (bv-pointer salt) (bytevector-length salt)
                       1 32 (bytevector->pointer out)))
    out))

;;; ssh-ed25519 recipients use the birational map from RFC 7748, section 4.1.
;;; The private conversion is RFC 8032, section 5.1.5.  Exact Scheme integers
;;; avoid another foreign interface: only X25519 and AEAD call libgcrypt.
(define ed25519-field-prime (- (expt 2 255) 19))
(define (ed25519-public->x25519 public)
  "Return the Curve25519 u-coordinate of a 32-byte Ed25519 public key."
  (unless (= 32 (bytevector-length public))
    (error "Ed25519 public key must be 32 bytes"))
  (let* ((y (logand (bytevector-uint-ref public 0 (endianness little) 32)
                    (- (expt 2 255) 1)))
         (u (modulo (* (+ 1 y)
                       (modulo-expt (modulo (- 1 y) ed25519-field-prime)
                                    (- ed25519-field-prime 2)
                                    ed25519-field-prime))
                    ed25519-field-prime))
         (out (make-bytevector 32)))
    (bytevector-uint-set! out 0 u (endianness little) 32)
    out))
(define (ed25519-seed->x25519 seed)
  "Return the X25519 secret derived from an Ed25519 seed."
  (unless (= 32 (bytevector-length seed))
    (error "Ed25519 seed must be 32 bytes"))
  (let ((digest (bytevector-hash seed (hash-algorithm sha512)))
        (out (make-bytevector 32)))
    (bytevector-copy! digest 0 out 0 32)
    out))

(define ecc-mul-point
  (foreign-procedure int "gcry_ecc_mul_point" (list int '* '* '*)))

(define (x25519 secret public)
  "Return the X25519 product of 32-byte SECRET and PUBLIC."
  (unless (and (= 32 (bytevector-length secret))
               (= 32 (bytevector-length public)))
    (error "X25519 keys must be 32 bytes"))
  (let ((result (make-bytevector 32)))
    (check "X25519"
           (ecc-mul-point 1 (bytevector->pointer result)
                          (bytevector->pointer secret)
                          (bytevector->pointer public)))
    (when (every zero? (bytevector->u8-list result))
      (error "X25519 produced an all-zero shared secret"))
    result))

(define (x25519-public-key secret)
  "Compute the Curve25519 public key for a 32-byte SECRET."
  (unless (= 32 (bytevector-length secret))
    (error "X25519 key must be 32 bytes"))
  (let ((result (make-bytevector 32)))
    (check "X25519 public key"
           (ecc-mul-point 1 (bytevector->pointer result)
                          (bytevector->pointer secret) %null-pointer))
    result))

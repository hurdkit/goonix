;;; goonix: libgcrypt primitive tests against RFC 7748 and RFC 8439.
(use-modules (guix secrets gcrypt)
             (gcrypt base16)
             (rnrs bytevectors) (srfi srfi-64))

(define (hex s) (base16-string->bytevector s))
(define alice-secret
  (hex "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))
(define bob-secret
  (hex "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"))
(define alice-public
  (hex "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"))
(define bob-public
  (hex "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"))

(test-begin "secrets-age-primitives")
(test-equal "RFC 7748 section 6.1 Alice public key" alice-public
  (x25519-public-key alice-secret))
(test-equal "RFC 7748 section 6.1 Bob public key" bob-public
  (x25519-public-key bob-secret))
(test-equal "RFC 7748 section 5.2 first vector"
  (hex "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
  (x25519 (hex "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4")
          (hex "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")))
(test-equal "RFC 7748 shared secret"
  (hex "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
  (x25519 alice-secret bob-public))
(test-error "X25519 rejects a small-order point" #t
  (x25519 alice-secret (make-bytevector 32 0)))
(test-end)

;; RFC 8032 section 7.1, tests 1 to 3.  The two conversions must agree:
;; mapping the public point equals X25519's public key of the hashed seed.
(test-begin "ssh-ed25519-to-x25519")
(for-each
 (lambda (seed public)
   (test-equal "RFC 8032 key pair has matching converted public key"
     (x25519-public-key (ed25519-seed->x25519 (hex seed)))
     (ed25519-public->x25519 (hex public))))
 '("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
   "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"
   "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7")
 '("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
   "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"
   "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025"))
(test-end)

(define aead-key
  (hex "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"))
(define aead-nonce
  (hex "070000004041424344454647"))
(define aead-plaintext
  (string->utf8 "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."))
(define aead-ciphertext
  (hex (string-append
        "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6"
        "3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36"
        "92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc"
        "3ff4def08e4b7a9de576d26586cec64b6116"
        "1ae10b594f09e26a7e902ecbd0600691")))
(test-begin "secrets-age-aead")
(test-equal "RFC 8439 section 2.8.2 ciphertext and tag" aead-ciphertext
  (chacha20-poly1305-seal aead-key aead-nonce aead-plaintext
                          (hex "50515253c0c1c2c3c4c5c6c7")))
(test-equal "RFC 8439 section 2.8.2 opens" aead-plaintext
  (chacha20-poly1305-open aead-key aead-nonce aead-ciphertext
                          (hex "50515253c0c1c2c3c4c5c6c7")))
(test-error "AEAD refuses a modified tag" #t
  (let ((bad (bytevector-copy aead-ciphertext)))
    (bytevector-u8-set! bad (- (bytevector-length bad) 1) 0)
    (chacha20-poly1305-open aead-key aead-nonce bad
                            (hex "50515253c0c1c2c3c4c5c6c7"))))
(test-end)

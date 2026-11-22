;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 7778777 <7778777@7778777.online>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.

(define-module (guix ca)
  #:use-module (gcrypt hash)
  #:use-module (srfi srfi-11)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 iconv)
  #:use-module (rnrs bytevectors)
  #:use-module (rnrs io ports)
  #:use-module ((guix base16) #:select (bytevector->base16-string))
  #:use-module ((guix base32) #:select (bytevector->nix-base32-string))
  #:use-module ((guix store) #:select (%store-prefix query-build-records))
  #:use-module (ice-9 match)
  #:export (build-records
            %ca-store-directory
            reserved-hash
            reserved-hash-part?
            self-token
            token-path
            token-store-path?
            placeholder
            placeholder-path?
            placeholder-identity
            validate-token-path
            tree-hash
            content-addressed-path
            resolved-addressed-path
            canonical-build-record-payload
            build-record-content-hash))

(define %ca-store-directory "/gnu/store")
(define %reserved-alphabet "eout")

;; Upstream's remove-store-references (guix/build/utils.scm) writes 32 #\e
;; characters followed by #\- as its nuke-refs marker, into every file it
;; processes and into every output that ships Guix's build modules.  That
;; string must never be a goonix name, so it is not reserved.  To keep the
;; exemption sound rather than fail-open, reserved-hash bumps a placeholder's
;; last character to #\o when all 31 encoded characters would be #\e: no
;; placeholder can then be that string.  The cost is that one digest shares
;; its name with the digest encoding to e...eo, a 2^-62 collision - the same
;; order as the collision 62 bits already allow between any two placeholders.
;; Tokens start with #\o, #\u or #\t and are unaffected.  Keep in step with
;; encodeReserved in nix/libstore/ca.cc.
(define %nuke-refs-marker (make-string 32 #\e))

(define (reserved-hash digest self?)
  "Encode 62 digest bits, with a self-token discriminator in character zero."
  (when (< (bytevector-length digest) 8)
    (error "CA token digest is too short" digest))
  (let ((result (make-string 32)))
    (string-set! result 0
                 (if self?
                     (string-ref %reserved-alphabet
                                 (+ 1 (modulo (bytevector-u8-ref digest 0) 3)))
                     #\e))
    (let loop ((index 1))
      (if (= index 32)
          (begin
            ;; Never produce upstream's nuke-refs marker (see above).
            (when (and (not self?) (string=? result %nuke-refs-marker))
              (string-set! result 31 #\o))
            result)
          (let* ((bit (+ 2 (* 2 (- index 1))))
                 (byte (bytevector-u8-ref digest (quotient bit 8)))
                 (shift (- 6 (modulo bit 8)))
                 (value (logand (ash byte (- shift)) 3)))
            (string-set! result index (string-ref %reserved-alphabet value))
            (loop (+ index 1)))))))

(define (reserved-hash-part? part)
  "The one shared predicate: PART is a reserved hash part when it is 32
characters of the reserved alphabet, EXCEPT upstream's nuke-refs marker,
which is ordinary upstream data and never a goonix name."
  (and (string? part)
       (= 32 (string-length part))
       (not (string=? part %nuke-refs-marker))
       (string-every (lambda (character)
                       (string-index %reserved-alphabet character))
                     part)
       #t))

(define (valid-name? name)
  (and (string? name)
       (not (zero? (string-length name)))
       (not (string-prefix? "." name))
       (not (string-contains name "/"))
       (string-every (lambda (character)
                       (or (char-alphabetic? character)
                           (char-numeric? character)
                           (string-index "+-._?=" character)))
                     name)))

(define (check-name name)
  (unless (valid-name? name)
    (error "invalid CA store name" name)))

(define (self-token output)
  (unless (and (string? output) (valid-name? output))
    (error "invalid output name" output))
  (reserved-hash (sha256 (string->utf8
                          (string-append "goonix:self-token:v1:" output)))
                 #t))

(define (token-path output name)
  (check-name name)
  (string-append (%store-prefix) "/" (self-token output) "-" name))

(define (placeholder derivation-bytes output name)
  (check-name name)
  (unless (and (bytevector? derivation-bytes)
               (string? output) (valid-name? output))
    (error "invalid placeholder input" derivation-bytes output))
  (let-values (((port get-hash) (open-hash-port (hash-algorithm sha256))))
    (put-bytevector port
                    (string->utf8
                     (string-append "goonix:placeholder:v1:"
                                    (number->string
                                     (bytevector-length derivation-bytes))
                                    ":" output ":")))
    (put-bytevector port derivation-bytes)
    (force-output port)
    (let ((hash (get-hash)))
      (close-port port)
      (string-append (%store-prefix) "/"
                     (reserved-hash hash #f) "-" name))))

(define (parse-reserved-path path)
  (and (string? path)
       (string-prefix? (string-append (%store-prefix) "/") path)
       (let ((base (basename path)))
         (and (> (string-length base) 33)
              (char=? #\- (string-ref base 32))
              (reserved-hash-part? (string-take base 32))
              (valid-name? (string-drop base 33))
              (list (string-take base 32) (string-drop base 33))))))

(define (token-store-path? path)
  (and=> (parse-reserved-path path)
         (lambda (parts)
           (not (char=? #\e (string-ref (car parts) 0))))))

(define (placeholder-path? path)
  (and=> (parse-reserved-path path)
         (lambda (parts)
           (char=? #\e (string-ref (car parts) 0)))))

(define (placeholder-identity path derivation-bytes output name)
  "Return the identity of PATH after proving it matches its declared inputs."
  (if (string=? path (placeholder derivation-bytes output name))
      (list derivation-bytes output name)
      (error "placeholder does not match the declared derivation and output"
             path)))

(define (validate-token-path path)
  (cond ((token-store-path? path) path)
        ((placeholder-path? path)
         (error "unresolved CA placeholder" path))
        (else (error "not a valid CA token or placeholder" path))))

;;;
;;; Build records: the Scheme mirror of the daemon's canonical signed payload.
;;; Format 1 (doc/goonix/content-addressing.md): domain string, version, then
;;; each field as a 64-bit little-endian length followed by its UTF-8 bytes,
;;; then the relocation-checked flag as a 64-bit integer.
;;;

(define (put-u64-le port value)
  (let ((bytes (make-bytevector 8 0)))
    (bytevector-u64-set! bytes 0 value (endianness little))
    (put-bytevector port bytes)))

(define (put-length-prefixed port text)
  (let ((bytes (string->utf8 text)))
    (put-u64-le port (bytevector-length bytes))
    (put-bytevector port bytes)))

(define (put-length-prefixed-bytes port bytes)
  (put-u64-le port (bytevector-length bytes))
  (put-bytevector port bytes))

(define (bytevector<? a b)
  (let ((length (min (bytevector-length a) (bytevector-length b))))
    (let loop ((i 0))
      (cond ((= i length) (< (bytevector-length a) (bytevector-length b)))
            ((= (bytevector-u8-ref a i) (bytevector-u8-ref b i))
             (loop (+ i 1)))
            (else (< (bytevector-u8-ref a i) (bytevector-u8-ref b i)))))))

(define %tree-domain (string->utf8 "goonix-tree-v1\0"))

(define (tree-hash path)
  "Return SHA-256 of PATH according to doc/goonix/content-addressing.md.
Read regular files in bounded chunks and never follow symbolic links."
  (let walk ((path path) (depth 0))
    (when (> depth 1024)
      (error "CA tree nesting exceeds 1024 directories" path))
    (let ((info (lstat path)))
      (case (stat:type info)
        ((regular)
         (let-values (((port digest) (open-hash-port (hash-algorithm sha256))))
           (put-bytevector port %tree-domain)
           (put-u8 port 1)
           (put-u8 port (if (zero? (logand (stat:mode info) #o100)) 0 1))
           (put-u64-le port (stat:size info))
           (call-with-input-file path
             (lambda (input)
               (let loop ((bytes (get-bytevector-n input (* 128 1024))))
                 (unless (eof-object? bytes)
                   (put-bytevector port bytes)
                   (loop (get-bytevector-n input (* 128 1024))))))
             #:binary #t)
           (force-output port)
           (let ((result (digest))) (close-port port) result)))
        ((symlink)
         (let-values (((port digest) (open-hash-port (hash-algorithm sha256))))
           (put-bytevector port %tree-domain)
           (put-u8 port 2)
           (put-length-prefixed port (readlink path))
           (force-output port)
           (let ((result (digest))) (close-port port) result)))
        ((directory)
         (let-values (((port digest) (open-hash-port (hash-algorithm sha256)))
                      ((entries) (sort (scandir path
                                         (lambda (name)
                                           (not (member name '("." "..")))))
                                       (lambda (a b)
                                         (bytevector<? (string->utf8 a)
                                                       (string->utf8 b))))))
           (put-bytevector port %tree-domain)
           (put-u8 port 3)
           (put-u64-le port (length entries))
           (for-each
            (lambda (entry)
              (put-length-prefixed port entry)
              (let ((child (walk (string-append path "/" entry) (+ depth 1))))
                (put-length-prefixed port (bytevector->base16-string child))))
            entries)
           (force-output port)
           (let ((result (digest))) (close-port port) result)))
        (else (error "unsupported file type in CA tree" path))))))

(define (content-addressed-path output name tree references)
  (check-name name)
  (unless (and (string? output) (valid-name? output)
               (bytevector? tree) (= 32 (bytevector-length tree)))
    (error "invalid CA content path inputs" output tree))
  (let-values (((port digest) (open-hash-port (hash-algorithm sha256))))
    (put-bytevector port (string->utf8 "goonix-content-v1\0"))
    (put-length-prefixed-bytes port tree)
    (put-u64-le port (length references))
    (for-each (lambda (reference) (put-length-prefixed port reference))
              (sort references string<?))
    (force-output port)
    (let ((name-hash (digest)))
      (close-port port)
      (ca-store-path (string-append "goonix-content:" output)
                     name-hash name))))

(define (ca-store-path type name-hash name)
  "Apply Guix's compressed store-path formula to TYPE and NAME-HASH."
  (let* ((input (string->utf8
                 (string-append type ":sha256:"
                                (bytevector->base16-string name-hash) ":"
                                (%store-prefix) ":" name)))
         (hash (sha256 input))
         (compressed (make-bytevector 20 0)))
    (do ((i 0 (+ i 1))) ((= i (bytevector-length hash)))
      (let ((j (modulo i 20)))
        (bytevector-u8-set! compressed j
                            (logxor (bytevector-u8-ref compressed j)
                                    (bytevector-u8-ref hash i)))))
    (string-append (%store-prefix) "/"
                   (bytevector->nix-base32-string compressed) "-" name)))

(define (resolved-addressed-path output name resolved-bytes)
  "Return the resolved-addressed store path for canonical RESOLVED-BYTES."
  (check-name name)
  (unless (and (string? output) (valid-name? output)
               (bytevector? resolved-bytes))
    (error "invalid resolved-addressed path inputs" output resolved-bytes))
  (ca-store-path (string-append "goonix-resolved:" output)
                 (sha256 resolved-bytes) name))

(define* (canonical-build-record-payload resolved-hash derivation output
                                         path origin
                                         #:key (relocation-checked? #f))
  "Return the canonical bytes signed for a goonix build record.  This must
agree byte-for-byte with the daemon's canonicalBuildRecordPayload."
  (let-values (((port get-content) (open-bytevector-output-port)))
    (put-bytevector port (string->utf8 "goonix-record-v1"))
    (put-u8 port 0)
    (put-u64-le port 1)
    (for-each (lambda (field) (put-length-prefixed port field))
              (list resolved-hash derivation output path origin))
    (put-u64-le port (if relocation-checked? 1 0))
    (let ((bytes (get-content)))
      (close-port port)
      bytes)))

(define* (build-record-content-hash resolved-hash derivation output
                                    path origin
                                    #:key (relocation-checked? #f))
  "Return the SHA-256 (as a bytevector) of the canonical record payload."
  (sha256 (canonical-build-record-payload resolved-hash derivation output
                                          path origin
                                          #:relocation-checked?
                                          relocation-checked?)))

(define (build-records store resolved-hash output)
  "Return the signed records that the daemon behind STORE has for OUTPUT of
the resolved derivation whose hash is RESOLVED-HASH, a bytevector.  Each is a
list: the resolved derivation, the output, the realised path, the origin,
1 or 0 for whether the relocation was checked, and the signature."
  (let loop ((fields  (query-build-records store resolved-hash output))
             (records '()))
    (match fields
      (()
       (reverse records))
      ((derivation output path origin checked signature . rest)
       (loop rest
             (cons (list derivation output path origin
                         (if (string=? checked "1") 1 0)
                         signature)
                   records)))
      (_
       (error "the daemon sent build records that are not six fields each"
              fields)))))

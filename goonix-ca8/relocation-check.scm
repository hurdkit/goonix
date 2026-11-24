;;; goonix: the plan's section 4.4 relocation check, as a script.
;;;
;;; "A self path that is hashed, encrypted, encoded some other way, cut into
;;; pieces shorter than 8 characters, or used to compute something ... For
;;; these there is one sound test: build twice with two different tokens and
;;; compare."  A package that fails is marked opaque.
;;;
;;; This performs that comparison on an ALREADY REALISED item, so it can run
;;; over a store a gate has built without rebuilding the chain: copy the item
;;; twice, rewrite its self references to two DIFFERENT tokens with the same
;;; rewriter adoption uses (guix build graft's rewrite-directory, which
;;; guix ca build graft calls in its first pass), then compare the two results
;;; with the tokens normalised out.
;;;
;;; If the item's only self dependence is the literal store path, both
;;; relocations agree.  If it hid the path in a hash, an encoding, a fragment
;;; or a computed file name, the rewriter cannot reach that copy and the two
;;; relocations differ - the failure the plan means.
;;;
;;; Usage:
;;;   guile -L . -s goonix-ca8/relocation-check.scm STORE ITEM...
;;;
;;; STORE is a store directory; ITEM is a store item name or an absolute path.
;;; The store is only READ (each item is copied out before rewriting), so a
;;; store a gate is still writing to is not disturbed.
;;;
;;; Exit: 0 every item relocates, 1 any fails, 2 usage/setup error.
;;; Per item: RELOCATE <name> PASS | RELOCATE <name> FAIL <reason>.

(use-modules (guix build graft)
             (guix build utils)
             (guix ca)
             (guix base32)
             (guix base16)
             (gcrypt hash)
             (ice-9 ftw)
             (ice-9 match)
             (ice-9 binary-ports)
             (rnrs bytevectors)
             (srfi srfi-1))

(define %store-prefix "/gnu/store")

(define (store-item-name path)
  (let ((base (basename path)))
    (if (and (> (string-length base) 33)
             (char=? #\- (string-ref base 32)))
        (substring base 33)
        base)))

(define (store-item-hash path)
  (substring (basename path) 0 32))

(define (token-for path salt)
  "A 32-character nix-base32 store hash, different per SALT: the plan's two
tokens.

Two constraints, both measured: a sha256 in nix-base32 is 52 characters, and
rewrite-directory validates a 32-character hash made of nix-base32 characters.
The tree's reserved-hash encoder is NOT usable here - its alphabet is \"eout\",
exactly the four characters nix-base32 EXCLUDES, so those hashes are rejected
as \"invalid replacement\" (that is the point of the reserved alphabet: CA
placeholders must never collide with a real store hash).  Take the first 32
characters of the nix-base32 digest instead."
  (substring (bytevector->nix-base32-string
              (sha256 (string->utf8
                       (string-append "goonix-relocation:" salt ":"
                                      (basename path)))))
             0 32))

(define (string-replace-all str sub rep)
  (let ((n (string-length sub)))
    (let loop ((i 0) (acc '()))
      (let ((j (string-contains str sub i)))
        (if j
            (loop (+ j n) (cons rep (cons (substring str i j) acc)))
            (string-concatenate-reverse (cons (substring str i) acc)))))))

(define (normalise-token bytes needle marker)
  "BYTES with every occurrence of NEEDLE replaced by MARKER, searched as BYTES.

Both are ASCII and the needle is a fixed-width 32-character store hash, so this
is safe on ELF and compiled .go alike: no decoding, no offset assumptions beyond
the replacement itself.  Returns a fresh bytevector."
  (let* ((n (bytevector-length needle))
         (m (bytevector-length marker))
         (len (bytevector-length bytes))
         (hits (let loop ((i 0) (acc '()))
                 (cond
                  ((> (+ i n) len) (reverse acc))
                  ((let same? ((k 0))
                     (cond ((= k n) #t)
                           ((= (bytevector-u8-ref bytes (+ i k))
                               (bytevector-u8-ref needle k)) (same? (+ k 1)))
                           (else #f)))
                   (loop (+ i n) (cons i acc)))
                  (else (loop (+ i 1) acc)))))
         (out (make-bytevector (+ len (* (length hits) (- m n))))))
    (let loop ((src 0) (dst 0) (hits hits))
      (if (null? hits)
          (begin (bytevector-copy! bytes src out dst (- len src)) out)
          (let ((at (car hits)))
            (bytevector-copy! bytes src out dst (- at src))
            (bytevector-copy! marker 0 out (+ dst (- at src)) m)
            (loop (+ at n) (+ dst (- at src) m) (cdr hits)))))))

(define (snapshot root token)
  "An alist of (relative-path . digest-or-link-target) for ROOT, with every
occurrence of TOKEN normalised to a fixed marker.  Two relocations that differ
only in their token then compare equal."
  (let ((out '())
        (prefix (string-length root)))
    (for-each
     (lambda (file)
       (let ((rel (substring file prefix))
             (st (lstat file)))
         (case (stat:type st)
           ((symlink)
            ;; A symlink target may itself carry the token.
            (set! out (cons (cons rel
                                  (string-append
                                   "link:"
                                   (string-replace-all (readlink file)
                                                       token "@TOKEN@")))
                            out)))
           ((regular)
            (let* ((bytes (call-with-input-file file get-bytevector-all))
                   (tb (string->utf8 token))
                   (marker (string->utf8 "@TOKEN@")))
              ;; Normalise the token in BINARY files too, not just text.  An
              ;; ELF that embeds its own store path (hello's bin/hello, gcc's
              ;; cpp/cc1/collect2) is not valid UTF-8 - measured: utf8->string
              ;; on bin/hello throws - so the old text-only pass hashed the raw
              ;; bytes with the token still in them and EVERY such item was
              ;; reported as "content differs", i.e. opaque, for a difference
              ;; that is exactly the token this test introduced.  Search bytes,
              ;; never decode.  The token is a fixed-width 32-character store
              ;; hash, so replacing it does not move any other content.
              (set! out
                    (cons (cons rel
                                (bytevector->base16-string
                                 (sha256 (normalise-token bytes tb marker))))
                          out))))
           (else #t))))
     (find-files root (const #t) #:directories? #t))
    (sort out (lambda (a b) (string<? (car a) (car b))))))

(define (relocate src dst token)
  "Rewrite SRC's self references to TOKEN, writing the result to DST.
Uses upstream's rewrite-directory, the primitive guix ca build graft uses.

The store prefix must be passed EXPLICITLY: rewrite-directory defaults to
(%store-directory), which in this build is /nix/store, while the items live
under /gnu/store.  With the default the mapping's prefix check fails and every
item is rejected as \"invalid replacement\" (measured)."
  (let* ((name (store-item-name src))
         (old (string-append %store-prefix "/" (store-item-hash src) "-" name))
         (new (string-append %store-prefix "/" token "-" name)))
    (rewrite-directory src dst (list (cons old new)) %store-prefix)
    dst))

(define (first-difference a b)
  "The first entry where two snapshots differ, as a readable reason."
  (let loop ((a a) (b b))
    (cond
     ((and (null? a) (null? b)) "same entries but unequal")
     ((null? a) (format #f "missing entry ~a" (caar b)))
     ((null? b) (format #f "extra entry ~a" (caar a)))
     ((not (string=? (caar a) (caar b)))
      (format #f "entry names differ: ~a vs ~a" (caar a) (caar b)))
     ((not (equal? (cdar a) (cdar b)))
      (format #f "content differs at ~a" (caar a)))
     (else (loop (cdr a) (cdr b))))))

(define (check-item src)
  (let* ((base (basename src))
         (tmp (or (getenv "GOONIX_RELOCATION_TMP") "/tmp"))
         (a (string-append tmp "/reloc-a-" base))
         (b (string-append tmp "/reloc-b-" base))
         (ta (token-for src "a"))
         (tb (token-for src "b")))
    (for-each (lambda (d)
                (when (file-exists? d)
                  (false-if-exception (delete-file-recursively d))))
              (list a b))
    (catch #t
      (lambda ()
        (relocate src a ta)
        (relocate src b tb)
        (let ((na (snapshot a ta))
              (nb (snapshot b tb)))
          (for-each (lambda (d)
                      (false-if-exception (delete-file-recursively d)))
                    (list a b))
          (if (equal? na nb)
              (list 'pass (format #f "~a entries" (length na)))
              (list 'fail (first-difference na nb)))))
      (lambda (key . args)
        (for-each (lambda (d)
                    (false-if-exception (delete-file-recursively d)))
                  (list a b))
        (list 'fail (format #f "~a ~a" key args))))))

(define (main args)
  (let* ((argv (cdr args))
         (store (and (pair? argv) (car argv)))
         (items (and (pair? argv) (cdr argv))))
    (cond
     ((or (not store) (null? items))
      (format (current-error-port)
              "usage: relocation-check.scm STORE ITEM...~%")
      2)
     (else
      (let loop ((items items) (failed 0) (total 0))
        (if (null? items)
            (begin
              (format #t "RELOCATION ~a items, ~a failed~%" total failed)
              (if (zero? failed) 0 1))
            (let* ((name (car items))
                   (path (if (absolute-file-name? name)
                             name
                             (string-append store "/" name))))
              (if (not (file-exists? path))
                  (begin
                    (format #t "RELOCATE ~a FAIL not-found~%" name)
                    (loop (cdr items) (+ failed 1) (+ total 1)))
                  (match (check-item path)
                    (('pass why)
                     (format #t "RELOCATE ~a PASS ~a~%" name why)
                     (loop (cdr items) failed (+ total 1)))
                    (('fail why)
                     (format #t "RELOCATE ~a FAIL ~a~%" name why)
                     (loop (cdr items) (+ failed 1) (+ total 1))))))))))))

(exit (main (command-line)))
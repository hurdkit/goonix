;;; goonix: known-answer calibration for the section 4.4 relocation check.
;;;
;;; Runs INSIDE goonix-ca8/ca8-core-run.sh, where /gnu/store is the job's own
;;; bind-mounted scratch store, so synthetic items can be created under the real
;;; store prefix without touching the host store.  check-item only READS files,
;;; so the items need no registration.
;;;
;;; Two things are measured here:
;;;  1. The BINARY normalisation fix: an item whose self reference lives in a
;;;     file that is not valid UTF-8 (an ELF, compiled .go) must PASS.  Before
;;;     the fix, snapshot() normalised the token only in text files, so every
;;;     such item was reported opaque for the very difference the test itself
;;;     introduced.  Measured on the host: hello-2.12.3 FAIL /bin/hello before,
;;;     PASS 50 entries after.
;;;  2. The BLIND SPOT of post-hoc rewriting: a self path that is hashed or
;;;     fragmented is NOT rewritten in either copy, so both copies keep the
;;;     SAME bytes and compare equal.  The check therefore cannot see it.  This
;;;     is why the plan's sound test is to BUILD twice with two different tokens
;;;     (goonix-ca8/relocation-two-builds.scm), not to rewrite a realised item.
;;;
;;; Exit 0 when every case matches its known answer.
(use-modules (guix) (guix store) (guix build utils) (guix base16) (guix base32)
             (gcrypt hash)
             (ice-9 match) (ice-9 ftw) (ice-9 binary-ports)
             (rnrs bytevectors) (srfi srfi-1) (srfi srfi-13))

;; Capture the store prefix BEFORE loading relocation-check.scm: that file
;; defines its own %store-prefix as the STRING "/gnu/store", which shadows the
;; (guix store) PROCEDURE of the same name in this module (measured: "Wrong type
;; to apply: \"/gnu/store\"").  Inside the runner both are the same value.
(define store-dir (%store-prefix))

(define check-item
  (let* ((forms (with-input-from-file "goonix-ca8/relocation-check.scm"
                  (lambda () (let loop ((acc '()))
                               (let ((f (read)))
                                 (if (eof-object? f) (reverse acc)
                                     (loop (cons f acc))))))))
         (body (filter (lambda (f) (not (and (pair? f) (eq? (car f) 'exit))))
                       forms)))
    (for-each (lambda (f) (primitive-eval f)) body)
    (module-ref (current-module) 'check-item)))

(define results '())
(define (report name got want)
  (let ((ok (equal? got want)))
    (set! results (cons ok results))
    (format #t "~a ~a: got ~a want ~a~%" (if ok "PASS" "FAIL") name got want)))

;; A 32-character nix-base32 hash, so rewrite-directory accepts the mapping.
(define (fake-hash seed)
  (substring (bytevector->nix-base32-string
              (sha256 (string->utf8 (string-append "cal:" seed)))) 0 32))

(define (mk seed build)
  (let ((root (string-append store-dir "/" (fake-hash seed) "-cal-" seed)))
    (when (file-exists? root) (delete-file-recursively root))
    (mkdir-p (string-append root "/bin"))
    (build root)
    root))

(define (put root rel bytes)
  (call-with-output-file (string-append root rel)
    (lambda (p) (put-bytevector p bytes)) #:binary #t))

;;; 1. Plain text self reference: the rewriter reaches it.
(define clean
  (mk "clean" (lambda (r) (put r "/bin/plain" (string->utf8 (string-append "self=" r "\n"))))))
(report "text self reference" (car (check-item clean)) 'pass)

;;; 2. BINARY self reference, with NUL bytes so it is not valid UTF-8.  This is
;;;    the regression for the normalisation fix: an ELF-shaped file carrying the
;;;    literal store path must still relocate.
(define binitem
  (mk "binary"
      (lambda (r)
        ;; ELF-shaped header, the literal self path, then trailing NULs, all
        ;; written to one port.  No bytevector-append: it is not in this
        ;; Guile's module set (measured).
        (call-with-output-file (string-append r "/bin/elf")
          (lambda (p)
            (put-bytevector p #vu8(127 69 76 70 2 1 1 0 0 0 0 0 0 0 0 0))
            (put-bytevector p (string->utf8 (string-append r "/lib")))
            (put-bytevector p #vu8(0 0 0 0 1 2 3 4)))
          #:binary #t))))
(report "binary (non-UTF-8) self reference" (car (check-item binitem)) 'pass)

;;; 3. HASHED self reference - the plan's 4.4 case.  Known answer for a SOUND
;;;    test is 'fail.  Record what this post-hoc check actually returns.
(define hashed
  (mk "hashed"
      (lambda (r)
        (put r "/bin/plain" (string->utf8 (string-append "self=" r "\n")))
        (put r "/bin/cache"
             (string->utf8 (bytevector->base16-string
                            (sha256 (string->utf8 r))))))))
(define hashed-got (car (check-item hashed)))
(format #t "BLIND-SPOT hashed self reference: check says ~a (a sound test says fail)~%"
        hashed-got)
(report "hashed self reference is NOT detected by post-hoc rewriting"
        hashed-got 'pass)

;;; 4. FRAGMENTED self reference: pieces shorter than the rewriter's span.
(define frag
  (mk "frag"
      (lambda (r)
        (put r "/bin/plain" (string->utf8 (string-append "self=" r "\n")))
        (put r "/bin/frag"
             (string->utf8 (string-join
                            (map (lambda (i) (substring (fake-hash "frag") i (+ i 4)))
                                 '(0 4 8 12 16 20 24 28))
                            "\n"))))))
(define frag-got (car (check-item frag)))
(format #t "BLIND-SPOT fragmented self reference: check says ~a~%" frag-got)
(report "fragmented self reference is NOT detected by post-hoc rewriting"
        frag-got 'pass)

(for-each (lambda (r) (false-if-exception (delete-file-recursively r)))
          (list clean binitem hashed frag))
(let ((ok (every identity results)))
  (format #t "RELOCATION_CALIBRATION ~a (~a checks)~%"
          (if ok "PASS" "FAIL") (length results))
  (exit (if ok 0 1)))
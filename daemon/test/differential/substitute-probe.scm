(use-modules (guix store) (guix derivations) (guix tests)
             (guix base32) (gcrypt hash) (ice-9 textual-ports)
             ((guix serialization) #:select (write-file-tree))
             (rnrs bytevectors) (srfi srfi-34))

(define (assert condition message)
  (unless condition (error message)))

(define (fixture-derivation store name)
  (derivation store name "/does-not-exist" '()))

(define text "substitute fixture\n")
(define duplicate-text
  (string-concatenate (make-list 400 "duplicate substitute payload\n")))

(with-store store
  (set-build-options store #:use-substitutes? #t #:fallback? #f
                     #:substitute-urls (%test-substitute-urls))
  (let* ((drv (fixture-derivation store "ordinary"))
         (out (derivation->output-path drv)))
    (with-derivation-substitute drv text
      (ensure-path store out))
    (assert (valid-path? store out) "ordinary substitute is not valid")
    (assert (string=? text (call-with-input-file out get-string-all))
            "ordinary substitute contents differ")
    (format #t "ordinary substitute: PASS\n")))

(with-store store
  (set-build-options store #:use-substitutes? #t #:fallback? #f
                     #:substitute-urls (%test-substitute-urls))
  (let* ((first (fixture-derivation store "duplicate-one"))
         (second (fixture-derivation store "duplicate-two"))
         (out1 (derivation->output-path first))
         (out2 (derivation->output-path second)))
    (with-derivation-substitute first duplicate-text
      (ensure-path store out1))
    (with-derivation-substitute second duplicate-text
      (ensure-path store out2))
    (assert (= (stat:ino (stat out1)) (stat:ino (stat out2)))
            "substitutes are not deduplicated")
    (format #t "substitute deduplication: PASS\n")))

(with-store store
  (set-build-options store #:use-substitutes? #t #:fallback? #f
                     #:print-build-trace #t
                     #:substitute-urls (%test-substitute-urls))
  (let* ((drv (fixture-derivation store "corrupt"))
         (out (derivation->output-path drv))
         (zero-hash (make-bytevector 32 0))
         (output #f)
         (failed? #f))
    ((module-ref (resolve-module '(guix tests)) 'call-with-derivation-substitute)
     drv "hello, world"
     (lambda ()
      (format (current-error-port) "CORRUPT_FIXTURE path=~a narinfo=~s\n"
              out
              (call-with-input-file
                  (string-append (%substitute-directory) "/"
                                 (store-path-hash-part out) ".narinfo")
                get-string-all))
      (set! output
            (call-with-output-string
             (lambda (port)
               (parameterize ((current-build-output-port port))
                 (set! failed?
                       (guard (condition ((store-protocol-error? condition) #t))
                         (ensure-path store out)
                         #f)))))))
     #:sha256 (make-bytevector 32 0))
    (assert failed? "corrupt substitute was accepted")
    (assert (not (valid-path? store out)) "corrupt substitute became valid")
    (assert (string-contains output "@ hash-mismatch ")
            "corrupt substitute lacks hash-mismatch trace")
    (assert (string-contains output "@ substituter-failed ")
            "corrupt substitute lacks failure trace")
    (format #t "corrupt substitute: PASS\n")))

(with-store store
  (set-build-options store #:use-substitutes? #t
                     #:substitute-urls (%test-substitute-urls))
  (let* ((size (+ 100 (expt 2 31)))
         (item (string-append (%store-prefix)
                              "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-large-size"))
         (nar (string-append (%substitute-directory) "/large-size.nar")))
    (call-with-output-file nar
      (lambda (port)
        (write-file-tree "large-size" port
                         #:file-type+size (lambda _ (values 'regular 12))
                         #:file-port (lambda _ (open-input-string "Hello world.")))))
    (call-with-output-file
        (string-append (%substitute-directory) "/"
                       (store-path-hash-part item) ".narinfo")
      (lambda (port)
        (format port "StorePath: ~a\nURL: file://~a\nCompression: none\nNarSize: ~a\nNarHash: sha256:~a\nReferences: \nSystem: x86_64-linux\nFutureContentRecord: ignored\n"
                item nar size
                (bytevector->nix-base32-string (file-sha256 nar)))))
    (ensure-path store item)
    (assert (= size (path-info-nar-size (query-path-info store item)))
            "large substitute size changed")
    (format #t "large substitute size and unknown narinfo field: PASS\n")))

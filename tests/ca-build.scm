;;; goonix: end-to-end tests of content-addressed derivations.
(use-modules (guix)
             (guix tests)
             (guix ca)
             (gnu packages bootstrap)
             (guix derivations)
             (guix build utils)
             (ice-9 match)
             (ice-9 binary-ports)
             (ice-9 ftw)
             (ice-9 threads)
             (srfi srfi-1)
             (srfi srfi-26)
             (srfi srfi-34)
             (srfi srfi-64)
             (ice-9 textual-ports)
             (rnrs bytevectors)
             ((gcrypt hash) #:select (sha256)))

(test-begin "ca-build")
(define store (open-connection-for-tests))
(%graft? #f)
(define bash (add-to-store store "bash" #t "sha256"
                           (search-bootstrap-binary "bash" (%current-system))))
(define mkdir (add-to-store store "mkdir" #t "sha256"
                            (search-bootstrap-binary "mkdir" (%current-system))))
(define guile-drv (package-derivation store %bootstrap-guile))
(build-derivations store (list guile-drv))
(define bootstrap-guile (string-append (derivation->output-path guile-drv)
                                      "/bin/guile"))
(define bootstrap-guile-modules
  (string-append (derivation->output-path guile-drv)
                 "/share/guile/2.0"))
(define* (shell-drv name script #:key (inputs '()) (sources '())
                    (addressing 'content) (env-vars '()) (outputs '("out")))
  ;; Keep one builder text per script. A different source path for an
  ;; otherwise identical input-addressed builder changes its derivation.
  (let* ((input-paths (map (lambda (input)
                             (derivation->output-path (car input)))
                           inputs))
         (builder (string-append
                   "(use-modules (ice-9 rdelim))\n"
                   "(define (read-all port)\n"
                   " (let loop ((lines '()))\n"
                   "  (let ((line (read-line port 'concat)))\n"
                   "   (if (eof-object? line)\n"
                   "    (string-concatenate-reverse lines)\n"
                   "    (loop (cons line lines))))))\n"
                   "(define out (getenv \"out\"))\n"
                   "(define inputs (call-with-input-string (getenv \"input-paths\") read))\n"
                   "(define (mkdir-p directory)\n"
                   " (zero? (system* \"" mkdir "\" \"-p\" directory)))\n"
                   script "\n"))
         (builder-file (add-text-to-store store "builder.scm" builder)))
    (derivation store name bootstrap-guile
                `("--no-auto-compile"
                  ,(if (eq? addressing 'input)
                       builder-file
                       "$NIX_BUILD_TOP/builder.scm"))
                #:inputs `(,guile-drv ,@inputs)
                #:outputs outputs
                #:sources (if (eq? addressing 'input)
                              (list builder-file)
                              (list mkdir))
                #:addressing addressing
                #:env-vars
                `(("GUILE_LOAD_PATH" . ,bootstrap-guile-modules)
                  ("script" . ,script)
                  ("input-paths" . ,(object->string input-paths))
                  ("__files" . "builder.scm")
                  ("__file:builder.scm" . ,builder)
                  ,@env-vars))))

(define (write-output text)
  (string-append "(call-with-output-file out (lambda (p) (display " 
                 (object->string text) " p)))"))

(define (write-output-bytes bytes)
  (string-append "(use-modules (rnrs bytevectors) (ice-9 binary-ports))\n"
                 "(call-with-output-file out (lambda (p) (put-bytevector p "
                 (object->string bytes) ")) #:binary #t)"))

(define (read-all file) (call-with-input-file file get-string-all))
(define (read-binary file)
  (call-with-input-file file get-bytevector-all #:binary #t))
(define (realised drv) (realised-output-path store drv "out"))

(define (fresh-name prefix)
  ;; A new name on every run: the test store outlives a run, and some of
  ;; these assertions must observe a build rather than an existing choice.
  (string-append prefix "-"
                 (number->string (random 1000000000
                                         (random-state-from-platform)))))

(define (failed-build-log drv)
  ;; The final protocol error is generic.  The daemon's specific build
  ;; diagnostic is in its output, even at the default test verbosity.
  ;; Hold the port explicitly: call-with-output-string would return the
  ;; captured text even when the body returns #f after a successful build.
  (let ((log (open-output-string)))
    (guard (condition ((store-protocol-error? condition)
                       (get-output-string log)))
      (parameterize ((current-build-output-port log))
        (build-derivations store (list drv)))
      #f)))

(define (protocol-error-matching? drv text)
  (guard (condition ((store-protocol-error? condition)
                     (string-contains (store-protocol-error-message condition) text)))
    (build-derivations store (list drv))
    #f))

(define (build-fails-with? drv text)
  (let ((log (failed-build-log drv)))
    (when (or (not log) (not (string-contains log text)))
      (format (current-error-port) "expected build failure ~s for ~a; log: ~s\n"
              text (derivation-file-name drv) log))
    (and (string? log) (string-contains log text) text)))

(define (matching-store-files suffix)
  (map (lambda (name) (string-append (%store-prefix) "/" name))
       (scandir (%store-prefix)
                (lambda (name) (string-suffix? suffix name)))))

(define (count-build-started log drv)
  "Count actual daemon build events for DRV, not protocol build requests."
  (let ((prefix (string-append "@ build-started " drv " ")))
    (length (filter (lambda (line) (string-prefix? prefix line))
                    (string-split log #\newline)))))

(define (build-recording-events drvs)
  "Build DRVS and return their daemon build log as a string."
  (let ((log (open-output-string)))
    (parameterize ((current-build-output-port log))
      (build-derivations store drvs))
    (get-output-string log)))

(define (build-started-path log)
  (let* ((prefix "@ build-started ")
         (line (find (lambda (line) (string-prefix? prefix line))
                     (string-split log #\newline))))
    (and line
         (first (string-split (string-drop line (string-length prefix))
                              #\space)))))

(define (resolved-derivation-for drv)
  (path-info-deriver (query-path-info store (realised drv))))

(define (resolved-derivation-with-output name output)
  (find (lambda (file)
          (let ((text (read-all file)))
            (and (string-contains text "goonixResolved")
                 (string-contains text output))))
        (matching-store-files (string-append "-" name ".drv"))))

(define (failed-partial-derivation name)
  (let ((drv (shell-drv name
                        "(call-with-output-file out (lambda (p) (display out p)))"
                        #:outputs '("out" "missing"))))
    (guard (condition ((store-protocol-error? condition)
                       (resolved-derivation-with-output name "missing")))
      (build-derivations store (list drv))
      #f)))

(define (successful-partial-retry name)
  (let ((drv (shell-drv name
                        "(call-with-output-file out (lambda (p) (display out p)))\n(call-with-output-file (getenv \"missing\") (lambda (p) (display \"ok\" p)))"
                        #:outputs '("out" "missing"))))
    (build-derivations store (list drv))
    (realised drv)))

(test-group "input-addressed derivation compatibility"
  ;; Literal canonical upstream derivation, independent of the CA constructor.
  ;; Its output hash is the SHA-256 of this byte sequence.
  (let* ((text "Derive([(\"out\",\"\",\"\",\"\")],[],[],\"x86_64-linux\",\"/bin/sh\",[\"-c\",\"printf legacy > \\\"$out\\\"\"],[(\"out\",\"\")])")
         (expected "/gnu/store/xi66n3jhg82kr6bn6l1ggxik9irl7z14-legacy-identity")
         (drv (read-derivation (open-input-string text))))
    (test-equal "upstream input-addressed output path"
      expected (parameterize ((%store-prefix "/gnu/store"))
                 ((@@ (guix store) output-path)
                  "out" (derivation-hash drv) "legacy-identity")))
    (test-equal "upstream input-addressed derivation bytes round-trip"
      (string->utf8 text)
      (derivation->bytevector (derivation/masked-inputs drv)))
    (test-equal "input-addressed derivation has no CA addressing metadata"
      #f (assoc "goonixAddressing" (derivation-builder-environment-vars drv)))
    (test-equal "input-addressed derivation has no placeholder"
      #f (placeholder-path? (derivation->output-path drv)))
    (test-equal "input-addressed derivation has no self token"
      #f (token-store-path? (derivation->output-path drv)))))

(test-group "unused variables retain distinct resolved derivations"
  (let* ((name (fresh-name "ca-unused"))
         (one (shell-drv name (write-output "stable")
                         #:env-vars '(("unused" . "one"))))
         (two (shell-drv name (write-output "stable")
                         #:env-vars '(("unused" . "two"))))
         (token (derivation->output-path one)))
    (test-equal "unused-variable derivation has a placeholder"
      #t (placeholder-path? token))
    (test-equal "unused-variable derivation identities differ"
      #f (string=? (derivation-file-name one) (derivation-file-name two)))
    (let* ((one-log (build-recording-events (list one)))
           (one-resolved (build-started-path one-log))
           (two-log (build-recording-events (list two)))
           (two-resolved (build-started-path two-log)))
      (test-equal "unused-variable resolved derivations differ"
        #f (string=? one-resolved two-resolved))
      (test-equal "two distinct resolved derivations build once each"
        2 (+ (count-build-started one-log one-resolved)
             (count-build-started two-log two-resolved)))
      (test-equal "unused-variable derivations share one result"
        (realised one) (realised two))
      (test-equal "unused-variable result contents"
        "stable" (read-all (realised one)))
      (test-equal "unused-variable builds are not cached failures"
        '() (query-failed-paths store)))))

(test-assert "a second identical CA result is reused without overwriting"
  (let* ((one (shell-drv "ca-existing" (write-output "same")
                         #:env-vars '(("unused" . "one"))))
         (two (shell-drv "ca-existing" (write-output "same")
                         #:env-vars '(("unused" . "two")))))
    (build-derivations store (list one))
    (let ((path (realised one)))
      (and (build-derivations store (list two))
           (string=? path (realised two))
           (string=? "same" (read-all path))))))

(test-assert "whole self references, file names and symlinks round-trip"
  (let* ((drv (shell-drv "ca-relocation"
                (string-append
                 "(mkdir out)\n"
                 "(call-with-output-file (string-append out \"/reference\") (lambda (p) (display out p)))\n"
                 "(mkdir-p (string-append out \"/\" (basename out)))\n"
                 "(symlink (basename out) (string-append out \"/link\"))\n"
                 "(call-with-output-file (string-append out \"/executable\") (lambda (p) (display \"#!/bin/sh\\n\" p)))\n"
                 "(chmod (string-append out \"/executable\") #o755)\n")))
         (path (begin (build-derivations store (list drv)) (realised drv))))
    (and (string=? path
                   (call-with-input-file
                    (string-append path "/reference") get-string-all))
         (string=? (basename path)
                   (readlink (string-append path "/link")))
         (file-exists? (string-append path "/" (basename path)))
         (verify-store store #:check-contents? #t #:repair? #f))))

(test-group "reserved placeholder read boundaries"
  (let* ((input (shell-drv "ca-reserved-boundary-input" (write-output "A")))
         (reserved (placeholder (derivation->bytevector input) "out"
                                "ca-reserved-boundary-input"))
         (hash-index (+ 1 (string-rindex reserved #\/)))
         (parts (list (substring reserved 0 24) (substring reserved 24)))
         (padding (- 131040 hash-index))
         (script (string-append
                  "(call-with-output-file out (lambda (p) (display (make-string "
                  (number->string padding) " #\\x) p) (display (string-append "
                  (object->string (car parts)) " " (object->string (cadr parts))
                  ") p) (display \"tail\" p)))")))
    (test-equal "placeholder starting 32 bytes before a read boundary is refused"
      "unresolved goonix placeholder"
      (build-fails-with? (shell-drv (fresh-name "ca-reserved-boundary") script)
                         "unresolved goonix placeholder"))))

;;; CA-2 is also runnable on its own from a small driver that loads these
;;; helpers first.  The full suite includes the same forms.
(include "ca-cutoff.scm")

(test-assert "--check preserves a self-referencing result and its choice"
  (let* ((drv (shell-drv "ca-check-self"
                         "(call-with-output-file out (lambda (p) (display out p)))"))
         (out (begin (build-derivations store (list drv)) (realised drv))))
    (build-derivations store (list drv) (build-mode check))
    (and (string=? out (read-all out))
         (string=? out (realised drv))
         (valid-path? store out)
         (verify-store store #:check-contents? #t #:repair? #f))))

(define (ca-deep-build drv)
  "Build DRV with deep scanning; return 'accepted or the captured daemon log."
  (let ((connection (open-connection-for-tests)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let ((log (open-output-string)))
          (set-build-options connection #:deep-scan? #t)
          (guard (condition ((store-protocol-error? condition)
                             (get-output-string log)))
            (parameterize ((current-build-output-port log))
              (build-derivations connection (list drv)))
            'accepted)))
      (lambda () (close-connection connection)))))

(define (ca-deep-refusal? result text)
  (and (string? result) (string-contains result text) text))

(test-group "CA-1: compressed self tokens and the deep-scan setting"
  (for-each
   (lambda (format)
     (let* ((bytes (read-binary (string-append "tests/fixtures/ca-self-token." format)))
            (name (fresh-name (string-append "ca-deep-" format))))
       (test-assert (string-append "ordinary finalisation accepts " format " self token")
         (let ((drv (shell-drv name (write-output-bytes bytes))))
           (build-derivations store (list drv))
           (valid-path? store (realised drv))))
       (test-equal (string-append "deep scan rejects " format " token at decoded offset")
         "unresolved goonix self token in decompressed"
         (let* ((drv (shell-drv (fresh-name (string-append "ca-deep-reject-" format))
                                (write-output-bytes bytes)))
                (connection (open-connection-for-tests)))
           (dynamic-wind
             (lambda () #t)
             (lambda ()
               (let ((log (open-output-string)))
                 (set-build-options connection #:deep-scan? #t)
                 (guard (condition ((store-protocol-error? condition)
                                    (let ((text (get-output-string log)))
                                      (and (string-contains text "unresolved goonix self token in decompressed")
                                           (string-contains text "byte 7")
                                           "unresolved goonix self token in decompressed"))))
                   (parameterize ((current-build-output-port log))
                     (build-derivations connection (list drv)))
                   #f)))
             (lambda () (close-connection connection)))))))
   '("gz" "xz" "bz2" "zip")))

(test-group "opaque self-reference encodings are refused"
  (let ((token (self-token "out")))
    (test-equal "a split self-token fragment is refused"
      "opaque self-reference fragment"
      (build-fails-with?
       (shell-drv "ca-split-token"
                  (write-output-bytes (string->utf8 (substring token 3 15))))
       "opaque self-reference fragment"))
    (for-each
     (lambda (width)
       (let ((bytes (u8-list->bytevector
                     (append-map
                      (lambda (character)
                        (append (list (char->integer character))
                                (make-list (- width 1) 0)))
                      (string->list token)))))
         (test-equal (format #f "a UTF-~aLE self token is refused" (* 8 width))
           (format #f "UTF-~a self-reference" (* 8 width))
           (build-fails-with?
            (shell-drv (format #f "ca-utf-~a" (* 8 width))
                       (write-output-bytes bytes))
            (format #f "UTF-~a self-reference" (* 8 width))))))
     '(2 4))))

(test-assert "resolved-addressed fallback builds at its final path"
  (let* ((drv (shell-drv "ca-resolved" (write-output "resolved")
                         #:addressing 'resolved))
         (path (begin (build-derivations store (list drv)) (realised drv))))
    (and (direct-store-path? path)
         (not (placeholder-path? path))
         (string=? "resolved" (read-all path)))))

(test-assert "sibling output references are rewritten and registered"
  (let ((drv (shell-drv "ca-multi"
                        "(mkdir-p out)\n(call-with-output-file (string-append out \"/reference\") (lambda (p) (display (getenv \"lib\") p)))\n(call-with-output-file (getenv \"lib\") (lambda (p) (display \"library\" p)))"
                        #:outputs '("lib" "out"))))
    (build-derivations store (list drv))
    (let ((lib (realised-output-path store drv "lib"))
          (out (realised-output-path store drv "out")))
      (and (string=? lib (read-all (string-append out "/reference")))
           (member lib (references store out))))))

(test-group "CA-1: all output tokens and helper boundaries"
  (test-equal "a sibling output token in a compressed member is refused"
    "unresolved goonix self token"
    (let ((sibling
           (shell-drv (fresh-name "ca-deep-sibling")
                      (string-append
                       "(use-modules (rnrs bytevectors) (ice-9 binary-ports))\n"
                       "(call-with-output-file out (lambda (p) (display \"ok\" p)))\n"
                       "(call-with-output-file (getenv \"doc\") (lambda (p) (put-bytevector p "
                       (object->string (read-binary "tests/fixtures/ca-self-token.gz"))
                       ")) #:binary #t)")
                      #:outputs '("out" "doc"))))
      (ca-deep-refusal? (ca-deep-build sibling) "unresolved goonix self token")))
  (test-equal "a decoded placeholder 32 bytes before a chunk boundary is refused"
    "unresolved goonix placeholder"
    (ca-deep-refusal?
     (ca-deep-build
      (shell-drv (fresh-name "ca-deep-placeholder-boundary")
                 (write-output-bytes
                  (read-binary "tests/fixtures/ca-placeholder-boundary.gz"))))
     "unresolved goonix placeholder")))

(define (partial-failure-is-clean? name)
  (let* ((resolved (failed-partial-derivation name))
         (hash (sha256 (string->utf8 (read-all resolved)))))
    (and resolved
         (null? (query-build-records store hash "out"))
         (every (negate file-exists?)
                (matching-store-files (string-append "-" name))))))

(define (partial-retry-is-valid? name)
  (let* ((out (successful-partial-retry name))
         (contents (read-all out)))
    (and (valid-path? store out) (string=? out contents))))

(test-assert "a failed sibling leaves no record or final tree, and can be retried"
  (let ((name (fresh-name "ca-partial")))
    (and (partial-failure-is-clean? name)
         (partial-retry-is-valid? name))))

(test-assert "a successful build has no failure log"
  (let ((drv (derivation store "ca-success-log" bash
                         '("-c" "printf 'failed to produce output' >&2; printf ok > \"$out\"")
                         #:sources (list bash) #:addressing 'content)))
    (not (failed-build-log drv))))

(test-assert "a missing CA output is an ordinary build failure"
  (let ((drv (derivation store "ca-missing" bash '("-c" "exit 0")
                         #:sources (list bash) #:addressing 'content)))
    (and (build-fails-with? drv "failed to produce output")
         (string? (derivation-file-name drv)))))

(test-assert "a CA output obeys its self-reference policy"
  (let ((drv (derivation store "ca-disallowed-self" bash
                         '("-c" "printf %s \"$out\" > \"$out\"")
                         #:sources (list bash) #:addressing 'content
                         #:disallowed-references '("out"))))
    (build-fails-with? drv "not allowed to refer")))

(test-assert "a CA output obeys disallowed input references"
  (let ((drv (derivation store "ca-disallowed-input" bash
                         '("-c" "printf %s \"$input\" > \"$out\"")
                         #:sources (list bash) #:addressing 'content
                         #:env-vars (list (cons "input" bash))
                         #:disallowed-references (list bash))))
    (build-fails-with? drv "not allowed to refer")))

(test-assert "a malformed CA derivation is refused without dropping the connection"
  (let ((text (string-append
               "Derive([(\"out\",\"/not-a-store/output\",\"\",\"\")],[],[],"
               "\"x86_64-linux\",\"/bin/sh\",[],[(\"goonixAddressing\",\"content\"),"
               "(\"out\",\"/not-a-store/output\")])")))
    (and (guard (condition ((store-protocol-error? condition) #t))
           (add-text-to-store store "malformed.drv" text)
           #f)
         (valid-path? store bash)
         (let ((ordinary (derivation store "ca-after-malformed" bash
                                     '("-c" "printf ok > \"$out\"")
                                     #:sources (list bash) #:addressing 'content)))
           (build-derivations store (list ordinary))
           (string=? "ok" (read-all (realised ordinary)))))))

(test-assert "two goals for one resolved derivation build only once"
  (let ((drv (shell-drv (fresh-name "ca-concurrent") (write-output "same"))))
    ;; Both requests carry the same unresolved derivation, so both goals
    ;; resolve to the same R and must share the single recorded result.
    ;; Count the daemon's build events, not a file hidden from the builder.
    (let* ((one (open-connection-for-tests))
           (two (open-connection-for-tests))
           (one-log (open-output-string))
           (two-log (open-output-string))
           (request
            (lambda (connection log)
              (lambda ()
                (dynamic-wind
                  (const #t)
                  (lambda ()
                    (catch #t
                      (lambda ()
                        (parameterize ((current-build-output-port log))
                          (build-derivations connection (list drv))
                          (realised-output-path connection drv "out")))
                      (lambda (key . args)
                        (list 'failed key args (get-output-string log)))))
                  (lambda () (close-connection connection))))))
           (first (call-with-new-thread (request one one-log)))
           (second (call-with-new-thread (request two two-log)))
           (one-result (join-thread first))
           (two-result (join-thread second))
           (valid-results?
            (and (string? one-result) (string? two-result))))
      (unless valid-results?
        (format (current-error-port) "concurrent request results: ~s ~s\n"
                one-result two-result))
      (and valid-results?
           (let* ((resolved (path-info-deriver
                             (query-path-info store one-result)))
                  (started (string-append "@ build-started " resolved " "))
                  (logs (string-append (get-output-string one-log)
                                       (get-output-string two-log)))
                  (starts (filter (lambda (line)
                                    (string-prefix? started line))
                                  (string-split logs #\newline))))
             (and (string=? one-result two-result)
                  (= 1 (length starts))))))))

(test-assert "a fixed output in a CA derivation obeys its declared hash"
  (let ((drv (derivation store "ca-fixed-hash" bash
                         '("-c" "printf fixed > \"$out\"")
                         #:sources (list bash) #:addressing 'content
                         #:hash (sha256 (string->utf8 "wrong"))
                         #:hash-algo 'sha256)))
    (build-fails-with? drv "hash mismatch")))

(test-assert "a fixed output in a CA derivation accepts its declared hash"
  (let ((drv (derivation store "ca-fixed-valid" bash
                         '("-c" "printf fixed > \"$out\"")
                         #:sources (list bash) #:addressing 'content
                         #:hash (sha256 (string->utf8 "fixed"))
                         #:hash-algo 'sha256)))
    (and (build-derivations store (list drv))
         (string=? "fixed" (read-all (derivation->output-path drv))))))

(test-assert "resolved-addressed paths hash the final resolved derivation"
  (let* ((one (shell-drv "ca-resolved-cutoff" (write-output "same")
                        #:addressing 'resolved #:env-vars '(("v" . "one"))))
         (two (shell-drv "ca-resolved-cutoff" (write-output "same")
                        #:addressing 'resolved #:env-vars '(("v" . "two"))))
         (one-resolved (begin (build-derivations store (list one))
                              (path-info-deriver
                               (query-path-info store (realised one)))))
         (two-resolved (begin (build-derivations store (list two))
                              (path-info-deriver
                               (query-path-info store (realised two))))))
    ;; An unused environment entry is retained in R, so these are two
    ;; different resolved derivations.  This assertion guards against
    ;; accidentally identifying them; identical R cutoff is tested below.
    (and (not (string=? one-resolved two-resolved))
         (string=? "same" (read-all (realised one)))
         (string=? "same" (read-all (realised two))))))

(test-assert "identical resolved derivations have one resolved-addressed path"
  (let ((one (shell-drv "ca-resolved-same" (write-output "same")
                        #:addressing 'resolved))
        (two (shell-drv "ca-resolved-same" (write-output "same")
                        #:addressing 'resolved)))
    (build-derivations store (list one two))
    (string=? (realised one) (realised two))))

(test-group "upstream's nuke-refs marker is not a goonix reserved name"
  ;; Upstream's remove-store-references (guix/build/utils.scm) writes the
  ;; constant "/gnu/store/<32 e's>-" into every file it processes, and every
  ;; output shipping guix/build/utils.scm or .go carries that literal.  It
  ;; must NOT be treated as an unresolved placeholder: it is ordinary
  ;; upstream data.  Sound because no goonix name can be 32 e's — a
  ;; placeholder whose 31 encoded characters would all be 'e' has its last
  ;; character bumped to 'o' (see reserved-hash / encodeReserved).
  (define nuke-marker
    (string-append (%store-prefix) "/" (make-string 32 #\e) "-foo"))

  (test-assert "the marker is not a reserved path"
    (not (or (placeholder-path? nuke-marker)
             (token-store-path? nuke-marker))))

  (test-assert "a CA output containing the marker builds and registers"
    (let* ((drv (shell-drv (fresh-name "ca-nuke-literal")
                           (write-output nuke-marker)))
           (out (begin (build-derivations store (list drv)) (realised drv))))
      (and (valid-path? store out)
           (string-contains (read-all out) nuke-marker))))

  (test-assert "a CA output written THROUGH remove-store-references builds"
    ;; The real path by which the marker enters outputs: a file holding a
    ;; genuine store reference is nuked, leaving 32 e's in the result.  The
    ;; nuke pattern is reproduced in the builder from upstream's own
    ;; definition rather than imported: the builder runs BOOTSTRAP guile 2.0,
    ;; whose module tree does not carry our guix/build/utils.scm, and the
    ;; source tree is not in the build sandbox.  The constant written is
    ;; upstream's, byte for byte (guix/build/utils.scm:1329).
    (let* ((dep (shell-drv (fresh-name "ca-nuke-dep") (write-output "DEP")))
           (dep-out (begin (build-derivations store (list dep)) (realised dep)))
           (script
            (string-append
             "(call-with-output-file out (lambda (p) (display "
             (object->string dep-out) " p)))\n"
             ;; Upstream's substitution: prefix + slash + 32 hash chars + hyphen
             ;; becomes prefix + slash + 32 e's + hyphen.
             "(let* ((text (call-with-input-file out read-all))\n"
             "       (at (string-rindex text #\\/))\n"
             "       (nuked (string-append (substring text 0 (+ at 1))\n"
             "                            (make-string 32 #\\e)\n"
             "                            (substring text (+ at 33)))))\n"
             "  (call-with-output-file out (lambda (p) (display nuked p))))\n"))
           (drv (shell-drv (fresh-name "ca-nuke-refs") script))
           (out (begin (build-derivations store (list drv)) (realised drv))))
      (and (valid-path? store out)
           (string-contains (read-all out) (make-string 32 #\e)))))

  ;; A reserved path embedded WHOLE in the builder is refused earlier, as an
  ;; invalid input path.  To exercise the output SCAN the string is assembled
  ;; in the builder from two halves, exactly as the existing "reserved
  ;; placeholder read boundaries" group does.  The point stands: the exemption
  ;; is exactly the 32-e string and weakens nothing else.
  (define (split-reserved path)
    (let ((at (+ 1 (string-rindex path #\/))))
      (string-append
       "(call-with-output-file out (lambda (p) (display (string-append "
       (object->string (substring path 0 at)) " "
       (object->string (substring path at)) ") p)))")))

  (let* ((input (shell-drv (fresh-name "ca-nuke-real-input")
                           (write-output "A")))
         (real-placeholder (placeholder (derivation->bytevector input)
                                        "out" "ca-nuke-real-input")))
    (test-equal "a REAL unresolved placeholder in an output still fails"
      "unresolved goonix placeholder"
      (build-fails-with? (shell-drv (fresh-name "ca-nuke-real")
                                    (split-reserved real-placeholder))
                         "unresolved goonix placeholder")))

  (let ((near (string-append (%store-prefix) "/"
                             (make-string 31 #\e) "o-foo")))
    (test-assert "e...eo is a placeholder path"
      (placeholder-path? near))
    (test-equal "a placeholder one character off the marker is still refused"
      "unresolved goonix placeholder"
      (build-fails-with? (shell-drv (fresh-name "ca-nuke-near")
                                    (split-reserved near))
                         "unresolved goonix placeholder"))))

(close-connection store)
(test-end)

;;; goonix: two-store graph sharing fixture.  The caller isolates the store.
(use-modules (guix) (guix tests) (guix ca) (guix ca records) (guix store)
             (guix derivations)
             (gcrypt hash)
             (ice-9 match)
             (rnrs bytevectors) (srfi srfi-1) (srfi srfi-34) (rnrs io ports))

(define store (open-connection))
(%graft? #f)
(define shell-source (getenv "GOONIX_SHELL_SOURCE"))
(define shell (add-to-store store "two-store-shell" #t "sha256" shell-source))
(define sleep-source (getenv "GOONIX_SLEEP_SOURCE"))
(define sleep-path (and sleep-source
                        (add-to-store store "two-store-sleep" #t "sha256" sleep-source)))

(define* (ca-drv name script #:key (inputs '()) (addressing 'content)
                (env-vars '()) (sources '()))
  (derivation store name shell `("-c" ,script)
              #:sources (cons shell sources)
              #:inputs (map derivation-input inputs)
              #:addressing addressing #:env-vars env-vars))

(define (realised drv) (realised-output-path store drv "out"))
(define (field data name) (cadr (assq name data)))
(define (write-data file data)
  (call-with-output-file file (lambda (port) (write data port) (newline port))))
(define (read-data file) (call-with-input-file file read))
(define (read-all file) (call-with-input-file file get-string-all))
(define (assert-equal label expected actual)
  (unless (equal? expected actual)
    (error (string-append "goonix gate: " label) expected actual)))

(define (guarded-output text)
  (let ((marker (getenv "GOONIX_BUILD_MARKER")))
    (format #f "test -f '~a' || { printf 'client builder ran without server marker\\n' >&2; exit 73; }; read -r marker < '~a'; printf '%s\\n%s\\n' \"$marker\" '~a' > \"$out\""
            marker marker text)))

(define (nonreproducible-output)
  (let ((marker (getenv "GOONIX_BUILD_MARKER")))
    (format #f "test -f '~a' || { printf 'client builder ran without server marker\\n' >&2; exit 73; }; read -r tick < /proc/uptime; read -r marker < '~a'; printf '%s\\n%s\\n' \"$marker\" \"$tick\" > \"$out\""
            marker marker)))

(define (make-input)
  (ca-drv "two-store-input"
          (string-append
           (format #f "if test -e '~a/hold-enabled'; then until test -e '~a/hold-released'; do \"$sleep\" 1; done; fi; "
                   (getenv "GOONIX_ASYNC_ROOT") (getenv "GOONIX_ASYNC_ROOT"))
           (nonreproducible-output))
          #:sources (if sleep-path (list sleep-path) '())
          #:env-vars `(("sleep" . ,sleep-path))))
(define (make-dependent input)
  (ca-drv "two-store-dependent"
          "test -f \"$input\" || exit 74; printf '%s\\n' \"$input\" > \"$out\""
          #:inputs (list input)
          #:env-vars `(("input" . ,(derivation->output-path input)))))
(define (make-local-dependent input)
  (ca-drv "two-store-local-dependent"
          "test -f \"$input\" || exit 74; printf '%s\\n' \"$input\" > \"$out\""
          #:env-vars `(("input" . ,(derivation->output-path input)))
          #:inputs (list input)))
(define (make-later)
  (ca-drv "two-store-earlier" (guarded-output "shared")
          #:env-vars '(("unused" . "later"))))
(define (make-earlier)
  (ca-drv "two-store-earlier" (guarded-output "shared")
          #:env-vars '(("unused" . "earlier"))))

(define (server-fixture description)
  (let* ((earlier (make-earlier))
         (later (make-later))
         (input (make-input))
         (dependent (make-dependent input)))
    (call-with-output-file (getenv "GOONIX_BUILD_MARKER")
      (lambda (port) (display "server-only\n" port)))
    (build-derivations store (list earlier))
    (build-derivations store (list later))
    (build-derivations store (list dependent))
    (build-derivations store (list (fixed-output)))
    (let ((p1 (realised input))
          (dependent-out (realised dependent)))
      (sleep 2)
      (guard (c ((store-protocol-error? c) #t))
        (build-derivations store (list input) (build-mode check)))
      (delete-file (getenv "GOONIX_BUILD_MARKER"))
      (write-data description
        `((earlier ,(derivation-file-name earlier))
          (later ,(derivation-file-name later))
          (input ,(derivation-file-name input))
          (dependent ,(derivation-file-name dependent))
          (earlier-output ,(realised earlier))
          (later-output ,(realised later))
          (input-output ,p1)
          (dependent-output ,dependent-out))))))

(define (client-plain description)
  (let* ((data (read-data description))
         (later (make-later))
         (input (make-input))
         (dependent (make-dependent input))
         (local-dependent (make-local-dependent input)))
    (assert-equal "same later derivation" (field data 'later)
                  (derivation-file-name later))
    (assert-equal "same input derivation" (field data 'input)
                  (derivation-file-name input))
    (assert-equal "same dependent derivation" (field data 'dependent)
                  (derivation-file-name dependent))
    (build-derivations store (list later))
    (assert-equal "later uses server output" (field data 'later-output)
                  (realised later))
    (build-derivations store (list dependent))
    (build-derivations store (list dependent)) ; no second graph request
    (assert-equal "dependent uses server graph" (field data 'dependent-output)
                  (realised dependent))
    (assert-equal "input is the server's choice" (field data 'input-output)
                  (realised input))
    (assert-equal "dependent contains chosen input"
                  (field data 'input-output)
                  (string-trim-right (read-all (realised dependent))))
    (let* ((records (build-graph-records store (derivation-file-name dependent)))
           (input-hash
            (list-ref (find (lambda (record)
                              (string=? (field data 'input-output)
                                        (list-ref record 3)))
                            records)
                      0)))
      (assert-equal "dependent graph has a dependent record" 1
                    (length (filter (lambda (record)
                                      (string=? (field data 'dependent-output)
                                                (list-ref record 3)))
                                    records)))
      (assert-equal "input has two signed records" 2
                    (length (filter (lambda (record)
                                      (string=? (list-ref record 0) input-hash))
                                    records))))
    (write-data (string-append description ".plain-result")
                `((later ,(realised later))
                  (input ,(realised input))
                  (dependent ,(realised dependent))))))

(define (client-two-result description)
  (let* ((data (read-data description))
         (input (make-input))
         (dependent (make-dependent input)))
    (call-with-output-file (getenv "GOONIX_BUILD_MARKER")
      (lambda (port) (display "local-build-allowed\n" port)))
    (close-connection store)
    (let ((local-store (open-connection))
          (local-input #f))
      (set-build-options local-store #:use-substitutes? #f)
      (build-derivations local-store (list input))
      (set! local-input (realised-output-path local-store input "out"))
      (close-connection local-store)
      (set! store (open-connection))
      (set-build-options store #:use-substitutes? #t
                         #:substitute-urls (list (getenv "GOONIX_SERVER_URL")))
      (assert-equal "client made a distinct input result" #f
                    (string=? local-input (field data 'input-output)))
      (build-derivations store (list dependent))
      (let ((local-dependent (realised dependent)))
        (assert-equal "dependent rebuilt against local input" local-input
                      (string-trim-right (read-all local-dependent)))
        (assert-equal "server dependent was not adopted" #f
                      (string=? local-dependent (field data 'dependent-output)))
        (assert-equal "dependent references one input result"
                      (list local-input)
                      (filter (lambda (path)
                                (string-contains path "two-store-input"))
                              (requisites store (list local-dependent)))))
      (write-data (string-append description ".two-result")
                  `((local-input ,local-input)
                    (local-dependent ,(realised dependent))
                    (server-input ,(field data 'input-output)))))))

(define (client-concurrent description)
  (let* ((data (read-data description))
         (input (make-input))
         (dependent (make-dependent input))
         (local-dependent (make-local-dependent input)))
    (set-build-options store #:verbosity 5
                       #:use-substitutes? #t #:max-build-jobs 2
                       #:substitute-urls (list (getenv "GOONIX_SERVER_URL")))
    (call-with-output-file (getenv "GOONIX_BUILD_MARKER")
      (lambda (port) (display "concurrent-fallback\n" port)))
    (assert-equal "held input has the server's derivation"
                  (field data 'input) (derivation-file-name input))
    (build-derivations store (list dependent local-dependent))
    (let ((chosen (string-trim-right (read-all (realised dependent)))))
      (assert-equal "both dependent closures use the current input choice"
                    chosen
                    (string-trim-right (read-all (realised local-dependent))))
      (assert-equal "shared input is coherent"
                    (list chosen)
                    (delete-duplicates
                     (filter (lambda (path) (string-contains path "two-store-input"))
                             (requisites store (list (realised dependent)
                                                     (realised local-dependent)))))))))

(define (client-retry description)
  (let* ((data (read-data description))
         (later (make-later)))
    (set-build-options store #:use-substitutes? #t
                       #:substitute-urls (string-split
                                          (getenv "GOONIX_RETRY_URLS") #\space))
    (build-derivations store (list later))
    (assert-equal "next cache supplies the signed graph"
                  (field data 'later-output) (realised later))))

(define (client-unauthorized description)
  (let* ((data (read-data description))
         (later (make-later)))
    (set-build-options store #:use-substitutes? #t
                       #:substitute-urls (list (getenv "GOONIX_BAD_URL")))
    (call-with-output-file (getenv "GOONIX_BUILD_MARKER")
      (lambda (port) (display "unauthorized-local\n" port)))
    (build-derivations store (list later))
    (assert-equal "unauthorized graph does not select the server result" #f
                  (string=? (realised later) (field data 'later-output)))
    (assert-equal "unauthorized graph falls back to local build"
                  "unauthorized-local\nshared\n" (read-all (realised later)))))

(define (fixed-output)
  (let* ((fixed-content "dead-helper-nar")
         (fixed-hash (sha256 (string->utf8 fixed-content))))
    (derivation store "dead-fixed" shell
                `("-c" ,(format #f "printf '%s' '~a' > \"$out\"" fixed-content))
                #:sources (list shell)
                #:outputs '("out")
                #:hash fixed-hash #:hash-algo 'sha256)))

(define (client-dead description)
  (let* ((data (read-data description))
         (later (make-later))
         (fixed (fixed-output))
         (dependent (make-dependent (make-input))))
    (set-build-options store #:use-substitutes? #t #:max-build-jobs 1
                       #:substitute-urls (list (getenv "GOONIX_SERVER_URL")))
    (build-derivations store (list later fixed dependent))
    (write-data (string-append description ".dead")
                `((later ,(realised later))
                  (fixed ,(realised fixed))
                  (dependent ,(realised dependent))))))

(define (client-no-substitutes description)
  (close-connection store)
  (set! store (open-connection))
  (when (equal? "client" (getenv "GOONIX_NO_SUBSTITUTES_MODE"))
    (set-build-options store #:use-substitutes? #f))
  (let ((later (make-later))
        (data (read-data description)))
    (assert-equal "no-substitutes leaves the graph absent" #f
                  (false-if-exception (realised later)))
    ;; Local fallback is permitted; only a cache request would violate this gate.
    (call-with-output-file (getenv "GOONIX_BUILD_MARKER")
      (lambda (port) (display "no-substitutes-local\n" port)))
    (build-derivations store (list later))
    (assert-equal "no-substitutes performs a local build"
                  (string-append "no-substitutes-local\nshared\n")
                  (read-all (realised later)))))

(match (command-line)
  ((_ "server" description) (server-fixture description))
  ((_ "plain" description) (client-plain description))
  ((_ "two-result" description) (client-two-result description))
  ((_ "concurrent" description) (client-concurrent description))
  ((_ "retry" description) (client-retry description))
  ((_ "unauthorized" description) (client-unauthorized description))
  ((_ "dead" description) (client-dead description))
  ((_ "no-substitutes" description) (client-no-substitutes description))
  ((_ command . rest) (error "unknown fixture command" command rest)))

(close-connection store)

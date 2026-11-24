;;; goonix: adversarial tests of record sharing/selection (CA-5), collector
;;; reachability (plan 10) and mixed-policy safety (CA-4).  These exercise the
;;; store-side guarantees end-to-end against the test daemon: facts survive
;;; collection, choices are authoritative and repaired, disagreements are
;;; stored as second records, and an input-addressed derivation may not depend
;;; on a content-addressed one.
(use-modules (guix)
             (guix tests)
             (guix ca)
             (guix ca records)
             (guix store)
             (guix serialization)
             (guix base16)
             (gcrypt hash)
             (gnu packages bootstrap)
             (guix derivations)
             ((guix utils) #:select (string-replace-substring))
             (ice-9 match)
             (srfi srfi-1)
             (srfi srfi-34)
             (srfi srfi-64)
             (rnrs bytevectors)
             (rnrs io ports))

(test-begin "ca-sharing")
(define store (open-connection-for-tests))
(%graft? #f)
(define guile-drv (package-derivation store %bootstrap-guile))
(build-derivations store (list guile-drv))
(define bootstrap-guile (string-append (derivation->output-path guile-drv)
                                       "/bin/guile"))

;; Build a content/resolved/input-addressed derivation whose builder is the
;; bootstrap Guile running SCRIPT.  Inputs are passed as <derivation-input>.
(define* (ca-drv name script #:key (inputs '()) (addressing 'content)
                 (env-vars '()))
  (derivation store name bootstrap-guile
              `("--no-auto-compile" "-c" ,script)
              #:inputs (cons (derivation-input guile-drv)
                             (map derivation-input inputs))
              #:addressing addressing
              #:env-vars env-vars))

(define (write-output text)
  (string-append "(call-with-output-file (getenv \"out\") (lambda (p) (display "
                 (object->string text) " p)))"))

(define (read-all file) (call-with-input-file file get-string-all))
(define* (realised drv #:optional (output "out"))
  (realised-output-path store drv output))

(define make-derivation-output (@ (guix derivations) make-derivation-output))
(define make-derivation (@ (guix derivations) make-derivation))
(define make-store-path (@@ (guix store) make-store-path))

;; Reproduce the builder's resolution without consulting output derivers.
;; This is deliberately a test-side oracle for the graph protocol.
(define* (resolved-derivation drv #:key (name-of realised))
  (let* ((replacements
          (append-map
           (lambda (input)
             (let ((dependency (derivation-input-derivation input)))
               (map (lambda (output)
                      (cons (derivation->output-path dependency output)
                            (name-of dependency output)))
                    (derivation-input-sub-derivations input))))
           (derivation-inputs drv)))
         (substitute
          (lambda (text)
            (fold (lambda (replacement result)
                    (string-replace-substring result
                                              (car replacement)
                                              (cdr replacement)))
                  text replacements)))
         (addressing (assoc-ref (derivation-builder-environment-vars drv)
                                "goonixAddressing"))
         (outputs
          (map (match-lambda
                 ((name . output)
                  (cons name
                        (if (or (derivation-output-hash output)
                                (not addressing))
                            output
                            (make-derivation-output
                             (token-path
                              name
                              (store-path-package-name
                               (derivation-output-path output)))
                             (derivation-output-hash-algo output)
                             (derivation-output-hash output)
                             (derivation-output-recursive? output))))))
               (derivation-outputs drv)))
         (make
          (lambda (outputs marker?)
            (make-derivation
             outputs '()
             (sort (delete-duplicates
                    (append (derivation-sources drv) (map cdr replacements)))
                   string<?)
             (derivation-system drv)
             (substitute (derivation-builder drv))
             (map substitute (derivation-builder-arguments drv))
             (map (lambda (entry)
                    (cons (car entry)
                          (cond ((assoc (car entry) outputs)
                                 => (lambda (output)
                                      (derivation-output-path (cdr output))))
                                (else (substitute (cdr entry))))))
                  (sort (if marker?
                            (cons '("goonixResolved" . "1")
                                  (derivation-builder-environment-vars drv))
                            (derivation-builder-environment-vars drv))
                        (lambda (a b) (string<? (car a) (car b)))))
             #f)))
         (token-outputs
          (map (match-lambda
                 ((name . output)
                  (cons name
                        (if (derivation-output-hash output)
                            output
                            (make-derivation-output
                             (token-path
                              name
                              (store-path-package-name
                               (derivation-output-path output)))
                             #f #f #f)))))
               outputs))
         (initial (make token-outputs #f))
         (outputs
          (if (string=? addressing "resolved")
              (map (match-lambda
                     ((name . output)
                      (let ((original (assoc-ref (derivation-outputs drv) name)))
                        (cons name
                              (if (derivation-output-hash original)
                                  output
                                  (make-derivation-output
                                   (resolved-addressed-path
                                    name
                                    (store-path-package-name
                                     (derivation-output-path original))
                                    (derivation->bytevector initial))
                                   #f #f #f))))))
                   outputs)
              outputs)))
    (make outputs #t)))

(define (resolved-hash drv)
  (bytevector->base16-string
   (sha256 (derivation->bytevector (resolved-derivation drv)))))

(define (build-records hash output)
  ((@ (guix ca) build-records) store (base16-string->bytevector hash) output))

(define (record-paths hash output)
  (map (lambda (r) (list-ref r 2)) (build-records hash output)))

(define (resolved-store-path drv resolved)
  (let* ((name (string-append (derivation-name drv) ".drv"))
         (text (with-fluids ((%default-port-encoding "UTF-8"))
                 (call-with-output-string
                   (lambda (port) (write-derivation resolved port)))))
         (references (derivation-sources resolved)))
    (make-store-path (string-append "text:" (string-join references ":"))
                     (sha256 (string->utf8 text)) name)))

(test-assert "record query leaves the daemon connection synchronized"
  (let* ((drv (ca-drv "rec-sync" (write-output "sync")))
         (out (begin (build-derivations store (list drv)) (realised drv)))
         (records (build-records (resolved-hash drv) "out")))
    (and (= 1 (length records))
         (string=? out (list-ref (car records) 2))
         (valid-path? store out))))

(test-assert "a local build writes a signed record naming the realised path"
  (let* ((drv (ca-drv "rec-signed" (write-output "signed")))
         (out (begin (build-derivations store (list drv)) (realised drv)))
         (records (build-records (resolved-hash drv) "out")))
    (and (= 1 (length records))
         (string=? out (list-ref (car records) 2))
         (string=? "local" (list-ref (car records) 3))
         (not (string-null? (list-ref (car records) 5))))))

(test-assert "two derivations with one result share one path and one record"
  (let* ((one (ca-drv "rec-dedup" (write-output "same")
                      #:env-vars '(("unused" . "one"))))
         (two (ca-drv "rec-dedup" (write-output "same")
                      #:env-vars '(("unused" . "two")))))
    (build-derivations store (list one))
    (build-derivations store (list two))
    (and (string=? (realised one) (realised two))
         ;; The environment entry remains in each resolved derivation.  Check
         ;; the second one's record without claiming that the two R are equal.
         (= 1 (length (build-records (resolved-hash two) "out"))))))

(test-assert "the choice is authoritative across rebuilds"
  (let* ((drv (ca-drv "rec-choice" (write-output "chosen")))
         (out (begin (build-derivations store (list drv)) (realised drv))))
    (build-derivations store (list drv))
    (string=? out (realised drv))))

(test-assert "records and choices survive collection of the output"
  (let* ((drv (ca-drv "rec-survive" (write-output "survive")))
         (out (begin (build-derivations store (list drv)) (realised drv)))
         (hash (resolved-hash drv)))
    (delete-paths store (list out))
    (and (not (valid-path? store out))
         ;; The fact is permanent: it still names the collected path.
         (member out (record-paths hash "out")))))

(test-assert "a collected choice is repaired from the record on rebuild"
  (let* ((one (ca-drv "rec-repair" (write-output "repair")
                      #:env-vars '(("unused" . "one"))))
         (two (ca-drv "rec-repair" (write-output "repair")
                      #:env-vars '(("unused" . "two"))))
         (out (begin (build-derivations store (list one)) (realised one))))
    (delete-paths store (list out))
    (build-derivations store (list two))
    (and (string=? out (realised two))
         ;; The original derivation's stale choice is repaired too.
         (string=? out (realised one))
         (string=? "repair" (read-all out)))))

(test-assert "gc-keep-outputs keeps an output whose derivation is rooted"
  (let* ((drv (ca-drv "rec-keepout" (write-output "keepout")))
         (out (begin (build-derivations store (list drv)) (realised drv)))
         (drvfile (derivation-file-name drv)))
    ;; Enable keep-outputs for this connection, root the original derivation.
    ((@@ (guix store) set-options) store
     #:keep-failed? #f #:keep-going? #f #:fallback? #f #:verbosity 0
     #:offload? #f #:build-verbosity 0 #:log-type 0 #:print-build-trace #t
     #:use-substitutes? #f #:settings '(("gc-keep-outputs" . "true")))
    (add-permanent-root drvfile)
    (let ((alive (member out (live-paths store))))
      (remove-permanent-root drvfile)
      ;; Restore the default so later tests are not affected.
      ((@@ (guix store) set-options) store
       #:keep-failed? #f #:keep-going? #f #:fallback? #f #:verbosity 0
       #:offload? #f #:build-verbosity 0 #:log-type 0 #:print-build-trace #t
       #:use-substitutes? #f #:settings '(("gc-keep-outputs" . "false")))
      (->bool alive))))

(test-assert "gc-keep-outputs keeps an output via its record deriver"
  (let* ((drv (ca-drv "rec-keeprec" (write-output "keeprec")))
         (out (begin (build-derivations store (list drv)) (realised drv)))
         (hash (resolved-hash drv))
         (resolved-path (list-ref (car (build-records hash "out")) 0)))
    ((@@ (guix store) set-options) store
     #:keep-failed? #f #:keep-going? #f #:fallback? #f #:verbosity 0
     #:offload? #f #:build-verbosity 0 #:log-type 0 #:print-build-trace #t
     #:use-substitutes? #f #:settings '(("gc-keep-outputs" . "true")))
    ;; Root ONLY the resolved derivation; the output is kept via the record.
    (add-permanent-root resolved-path)
    (let ((alive (member out (live-paths store))))
      (remove-permanent-root resolved-path)
      ((@@ (guix store) set-options) store
       #:keep-failed? #f #:keep-going? #f #:fallback? #f #:verbosity 0
       #:offload? #f #:build-verbosity 0 #:log-type 0 #:print-build-trace #t
       #:use-substitutes? #f #:settings '(("gc-keep-outputs" . "false")))
      (->bool alive))))

(test-assert "--check preserves a self-referencing result and its choice"
  (let* ((drv (ca-drv "rec-check-self"
                      (string-append
                       "(call-with-output-file (getenv \"out\") "
                       "(lambda (p) (display (getenv \"out\") p)))")))
         (out (begin (build-derivations store (list drv)) (realised drv)))
         (hash (resolved-hash drv)))
    (build-derivations store (list drv) (build-mode check))
    (and (string=? out (read-all out))
         (string=? out (realised drv))
         (valid-path? store out)
         ;; A check is a distinct fact (origin local-check), even when it
         ;; reaches the same address.  Reproducibility means one result path.
         (equal? (list out) (delete-duplicates (record-paths hash "out")))
         (= 2 (length (build-records hash "out")))
         (verify-store store #:check-contents? #t #:repair? #f))))

(test-assert "--check stores a second record for a non-reproducible result"
  (let* ((drv (ca-drv "rec-nonrepro"
                      "(call-with-output-file (getenv \"out\") (lambda (p) (display (gettimeofday) p)))"))
         (out (begin (build-derivations store (list drv)) (realised drv)))
         (hash (resolved-hash drv)))
    (sleep 2)                          ; ensure a different timestamp
    (guard (c ((store-protocol-error? c) #t))
      (build-derivations store (list drv) (build-mode check)))
    (let ((paths (delete-duplicates (record-paths hash "out"))))
      (and (>= (length paths) 2)
           ;; The choice is unchanged by a check.
           (string=? out (realised drv))
           (member out paths)))))

(test-assert "the graph query returns dependency and dependent records"
  (let* ((input (ca-drv "graph-input" (write-output "input")))
         (dependent #f))
    (build-derivations store (list input))
    (set! dependent
          (ca-drv "graph-dependent"
                  (string-append
                   "(call-with-output-file (getenv \"out\") "
                   "(lambda (p) (display (getenv \"input\") p)))")
                  #:inputs (list input)
                  #:env-vars `(("input" . ,(realised input)))))
    (build-derivations store (list dependent))
    (let* ((records ((@ (guix ca records) build-graph-records)
                     store (derivation-file-name dependent)))
           (paths (map (lambda (record) (list-ref record 3)) records)))
      (and (= 2 (length records))
           (member (realised input) paths)
           (member (realised dependent) paths)))))

(test-assert "graph choice hints name the paths used in the dependent's R"
  (let* ((input (ca-drv "graph-hint-input"
                        "(call-with-output-file (getenv \"out\") (lambda (p) (display (gettimeofday) p)))"))
         (first (begin (build-derivations store (list input)) (realised input)))
         (dependent #f))
    (sleep 2)
    (guard (c ((store-protocol-error? c) #t))
      (build-derivations store (list input) (build-mode check)))
    (let ((paths (delete-duplicates (record-paths (resolved-hash input) "out"))))
      (test-assert "hint fixture has two records for its input"
        (and (>= (length paths) 2) (member first paths)))
      (set! dependent
            (ca-drv "graph-hint-dependent"
                    "(call-with-output-file (getenv \"out\") (lambda (p) (display (getenv \"input\") p)))"
                    #:inputs (list input)
                    #:env-vars `(("input" . ,(derivation->output-path input)))))
      (build-derivations store (list dependent))
      (call-with-values
          (lambda () (graph-response store (derivation-file-name dependent)))
        (lambda (records choices)
          (let* ((choice-alist
                  (map (lambda (choice)
                         (cons (list (car choice) (cadr choice))
                               (caddr choice)))
                       choices))
                 (chosen (assoc-ref choice-alist
                                    (list (derivation-file-name input) "out")))
                 (name-of (lambda (drv output)
                            (or (assoc-ref choice-alist
                                           (list (derivation-file-name drv) output))
                                (realised drv output))))
                 (hash (bytevector->base16-string
                        (sha256 (derivation->bytevector
                                 (resolved-derivation dependent #:name-of name-of)))))
                 (record (find (lambda (record)
                                 (and (string=? hash (list-ref record 0))
                                      (string=? (realised dependent)
                                                (list-ref record 3))))
                               records)))
            (and (string=? first chosen)
                 (member chosen paths)
                 (not (string=? (derivation->output-path input) chosen))
                 record
                 (string=? hash (resolved-hash dependent)))))))))

(test-group "a moved choice cannot leave a hint without its record"
  (define tag (number->string (random 1000000000 (random-state-from-platform))))
  (define input
    (ca-drv (string-append "graph-moved-input-" tag)
            "(call-with-output-file (getenv \"out\") (lambda (p) (display (gettimeofday) p)))"))
  (define (dependent-of name)
    (ca-drv (string-append name "-" tag)
            (string-append
             "(call-with-output-file (getenv \"out\") (lambda (p) "
             "(display (string-reverse (basename (getenv \"input\"))) p)))")
            #:inputs (list input)
            #:env-vars `(("input" . ,(derivation->output-path input)))))
  (define one (dependent-of "graph-moved-one"))
  (define two (dependent-of "graph-moved-two"))
  (build-derivations store (list one))
  (define p1 (realised input))
  (define d1 (realised one))
  (sleep 2)
  (guard (c ((store-protocol-error? c) #t))
    (build-derivations store (list input) (build-mode check)))
  (define-values (before-records before-hints)
    (graph-response store (derivation-file-name one)))
  (define one-record
    (find (lambda (record) (string=? d1 (list-ref record 3)))
          before-records))
  (test-assert "moved-choice fixture starts with the dependent's record"
    (and one-record
         (member (list (derivation-file-name one) "out" d1) before-hints)))
  (delete-paths store (list (list-ref one-record 1) p1))
  (define fresh (open-connection-for-tests))
  (build-derivations fresh (list two))
  (define p2 (realised-output-path fresh input "out"))
  (define d2 (realised-output-path fresh two "out"))
  (define-values (after-records after-hints)
    (graph-response fresh (derivation-file-name one)))
  (close-connection fresh)
  (test-assert "building the second dependent moves the input choice"
    (and (not (string=? p1 p2)) (not (string=? d1 d2))))
  (test-assert "the moved input hint still has a signed record"
    (and (member (list (derivation-file-name input) "out" p2) after-hints)
         (find (lambda (record) (string=? p2 (list-ref record 3)))
               after-records)))
  (test-assert "the old dependent gets no hint for its stale choice"
    (not (member (list (derivation-file-name one) "out" d1) after-hints)))
  (test-equal "every moved-choice hint is backed by a record"
    '()
    (filter (lambda (hint)
              (not (find (lambda (record)
                           (and (string=? (cadr hint) (list-ref record 2))
                                (string=? (caddr hint) (list-ref record 3))))
                         after-records)))
            after-hints)))

(test-assert "the graph query returns the later derivation's own record after collection"
  (let* ((name "graph-late-dedup")
         (one (ca-drv name (write-output "same")
                      #:env-vars '(("unused" . "one"))))
         (two (ca-drv name (write-output "same")
                      #:env-vars '(("unused" . "two")))))
    (build-derivations store (list one))
    (build-derivations store (list two))
    (let* ((expected (resolved-hash two))
           (out (realised two))
           (first-resolved (list-ref (car (build-records
                                           (resolved-hash one) "out")) 0))
           (records (build-graph-records store (derivation-file-name two))))
      (test-equal "the graph query uses the later derivation's resolved hash"
        expected (list-ref (car records) 0))
      (test-equal "the graph query returns the later derivation's result"
        out (list-ref (car records) 3))
      (test-equal "the graph query returns one record for the later derivation"
        1 (length records))
      (test-assert "the later resolved derivation differs from the first"
        (not (string=? first-resolved
                       (resolved-store-path two (resolved-derivation two)))))
      (delete-paths store (list first-resolved out))
      (let* ((fresh (open-connection-for-tests))
             (after (build-graph-records fresh (derivation-file-name two))))
        (close-connection fresh)
        (test-equal "the later record survives output and first deriver collection"
          (list expected out)
          (list (list-ref (car after) 0) (list-ref (car after) 3)))
        (test-equal "the collected graph query returns one record"
          1 (length after))
        #t))))

(test-assert "the graph query uses collected input names without changing choices"
  (let* ((input (ca-drv "graph-collected-input" (write-output "input")))
         (dependent
          (ca-drv "graph-collected-dependent"
                  (string-append
                   "(call-with-output-file (getenv \"out\") (lambda (p) "
                   "(display (file-exists? (getenv \"input\")) p)))")
                  #:inputs (list input)
                  #:env-vars `(("input" . ,(derivation->output-path input))))))
    (build-derivations store (list dependent))
    (let* ((input-out (realised input))
           (dependent-out (realised dependent))
           (before (build-graph-records store (derivation-file-name dependent)))
           (dependent-record
            (find (lambda (record) (string=? dependent-out (list-ref record 3)))
                  before))
           (expected (list-ref dependent-record 0))
           (input-hash (resolved-hash input)))
      (test-equal "collected-input graph starts with both records"
        2 (length before))
      (test-assert "the dependent does not refer to its build-time input"
        (not (member input-out (references store dependent-out))))
      (delete-paths store (list (list-ref dependent-record 1) input-out))
      (test-assert "the input is collected and the dependent remains valid"
        (and (not (valid-path? store input-out))
             (valid-path? store dependent-out)))
      (let* ((fresh (open-connection-for-tests))
             (after (build-graph-records fresh (derivation-file-name dependent))))
        (test-equal "collected-input graph retains both records"
          (map (lambda (record) (list-ref record 0)) before)
          (map (lambda (record) (list-ref record 0)) after))
        (test-equal "the graph query preserves the dependent's resolved hash"
          expected (list-ref (find (lambda (record)
                                     (string=? dependent-out (list-ref record 3)))
                                   after)
                             0))
        (test-equal "the collected input's record keeps the same resolved hash"
          input-hash
          (list-ref (find (lambda (record)
                            (string=? input-out (list-ref record 3))) after)
                    0))
        (close-connection fresh)
        #t))))

(test-assert "equal content from two derivations gives one coherent closure"
  (let* ((g1 (ca-drv "glibc" (write-output "GLIBC")))
         (g2 (ca-drv "glibc" (write-output "GLIBC")
                     #:env-vars '(("variant" . "two"))))
         (pkg-script
          ;; Embed the resolved dependency path so the output carries a real
          ;; runtime reference to the glibc item (that is what a closure is).
          "(use-modules (ice-9 rdelim)) (call-with-output-file (getenv \"out\") (lambda (p) (display (read-delimited \"\" (open-input-file (getenv \"dep\"))) p) (display \"-\" p) (display (getenv \"label\") p) (display \" ref:\" p) (display (getenv \"dep\") p)))")
         (pkg (lambda (name g label)
                (derivation store name bootstrap-guile
                            `("--no-auto-compile" "-c" ,pkg-script)
                            #:inputs (list (derivation-input guile-drv)
                                           (derivation-input g))
                            #:addressing 'content
                            #:env-vars `(("dep" . ,(derivation->output-path g))
                                         ("label" . ,label)))))
         (p1 (pkg "pkg1" g1 "P1"))
         (p2 (pkg "pkg2" g2 "P2")))
    (build-derivations store (list g1 g2))
    (build-derivations store (list p1 p2))
    (let* ((o1 (realised p1))
           (o2 (realised p2))
           (glibc-items (lambda (o)
                          (filter (lambda (p) (string-contains p "glibc"))
                                  (requisites store (list o))))))
      (and (string=? (realised g1) (realised g2))
           (string-prefix? "GLIBC-P1" (read-all o1))
           (string-prefix? "GLIBC-P2" (read-all o2))
           (= 1 (length (glibc-items o1)))
           (= 1 (length (glibc-items o2)))
           (equal? (glibc-items o1) (glibc-items o2))
           ;; Re-resolve after both dependents are realised: no goal may be
           ;; left asleep when all of its CA inputs already share a result.
           (build-derivations store (list p1 p2))
           (and (string=? o1 (realised p1))
                (string=? o2 (realised p2)))))))

(test-assert "an input-addressed derivation may not depend on a CA input"
  (let ((ca-input (ca-drv "ca-for-mixed" (write-output "X"))))
    ;; Registering an input-addressed derivation with a CA input must be
    ;; refused by the mixed policy (plan 3.1), before any build.
    (guard (c ((store-protocol-error? c)
               (string-contains (store-protocol-error-message c)
                                "mixed policy")))
      (derivation store "ia-mixed" bootstrap-guile
                  '("--no-auto-compile" "-c"
                    "(call-with-output-file (getenv \"out\") (lambda (p) (display \"Y\" p)))")
                  #:inputs (list (derivation-input ca-input))
                  #:addressing 'input)
      #f)))

(test-assert "input-addressed derivations stay byte-identical and buildable"
  (let* ((ia (ca-drv "ia-compat" (write-output "legacy") #:addressing 'input))
         (env (derivation-builder-environment-vars ia)))
    (and (not (assoc "goonixAddressing" env))
         (not (placeholder-path? (derivation->output-path ia)))
         (not (token-store-path? (derivation->output-path ia)))
         (build-derivations store (list ia))
         (string=? "legacy" (read-all (derivation->output-path ia))))))

(close-connection store)
(test-end)
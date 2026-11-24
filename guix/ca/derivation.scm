;;; goonix: derivation output addressing, kept out of upstream's constructor.
(define-module (guix ca derivation)
  #:use-module (guix ca)
  #:use-module (guix store)
  #:use-module (ice-9 match)
  #:export (validate-addressing
            add-addressed-output-paths
            addressing-environment))

(define (validate-addressing addressing)
  (unless (memq addressing '(input content resolved))
    (error "unknown derivation addressing" addressing)))

(define (output-name name output)
  (if (string=? output "out") name (string-append name "-" output)))

(define (add-addressed-output-paths masked name addressing
                                    ordinary-output-path fixed-output-path
                                    output-path output-hash output-algo
                                    output-recursive? make-output
                                    fields derivation-bytes derivation-hash
                                    package-name make)
  "Construct the addressed derivation from opaque data and supplied accessors.
The caller owns the record representation; this module owns addressing rules."
  (validate-addressing addressing)
  (let* ((fields (fields masked))
         (outputs (car fields))
         (env-vars (list-ref fields 6))
         (drv-hash (derivation-hash masked))
         (masked-bytes (derivation-bytes masked))
         (outputs
          (map (match-lambda
                 ((name* . output)
                  (let ((path
                         (cond
                          ((output-hash output)
                           (fixed-output-path name* (output-algo output)
                                              (output-hash output)
                                              (output-recursive? output)))
                          ((eq? addressing 'input)
                           (ordinary-output-path name* drv-hash name))
                          (else (token-path name* (output-name name name*))))))
                    (cons name* (make-output path (output-algo output)
                                             (output-hash output)
                                             (output-recursive? output))))))
               outputs)))
    (make
     (map (match-lambda
            ((name* . output)
             (cons name*
                   (if (or (eq? addressing 'input) (output-hash output))
                       output
                       (make-output
                        (placeholder masked-bytes name*
                                     (package-name (output-path output)))
                        (output-algo output) (output-hash output)
                        (output-recursive? output))))))
          outputs)
     (list-ref fields 1) (list-ref fields 2) (list-ref fields 3)
     (list-ref fields 4) (list-ref fields 5)
     (map (match-lambda
            ((variable . value)
             (cons variable (or (and=> (assoc-ref outputs variable) output-path)
                                value))))
          env-vars)
     #f)))

(define (addressing-environment addressing)
  (if (eq? addressing 'input)
      '()
      `(("goonixAddressing" . ,(symbol->string addressing)))))

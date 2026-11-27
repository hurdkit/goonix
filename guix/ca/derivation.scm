;;; goonix: derivation output addressing, kept out of upstream's constructor.
(define-module (guix ca derivation)
  #:use-module (guix ca)
  #:use-module (guix store)
  #:use-module ((guix remote-procedures) #:select (remote-procedure-id))
  #:use-module ((guix goonix-protocol) #:select (goonix-level-knows?))
  #:use-module ((guix diagnostics) #:select (formatted-message))
  #:use-module ((guix i18n) #:select (G_))
  #:use-module (srfi srfi-34)
  #:use-module (ice-9 match)
  #:export (validate-addressing
            assert-goonix-daemon
            add-addressed-output-paths
            addressing-environment))

(define (assert-goonix-daemon store name)
  "Raise an error unless the daemon behind STORE said in the greeting that it
is a goonix daemon.  NAME is what was about to be lowered with an addressing
other than upstream's, or under a policy other than upstream's.

A daemon that is not goonix's does not have content addressing: it cannot
build such a derivation, and it does not have the operation that tells where
the output of one went.  It is handed nothing of it.  This is called before
the first thing of NAME's lowering is added to the store, and there is no
falling back to upstream's addressing: what was asked for is not what
upstream's addressing gives."
  (unless (goonix-level-knows? (store-connection-goonix-level store)
                               (remote-procedure-id
                                query-realised-output/direct))
    (raise (formatted-message
            (G_ "~a: content addressing was asked for, but the build daemon is not a goonix daemon")
            name))))

(define (validate-addressing addressing)
  (unless (memq addressing '(input content resolved))
    (error "unknown derivation addressing" addressing)))

(define (output-name name output)
  (if (string=? output "out") name (string-append name "-" output)))

(define (add-addressed-output-paths store masked name addressing
                                    ordinary-output-path fixed-output-path
                                    output-path output-hash output-algo
                                    output-recursive? make-output
                                    fields derivation-bytes derivation-hash
                                    package-name make)
  "Construct the addressed derivation from opaque data and supplied accessors.
The caller owns the record representation; this module owns addressing rules.
STORE is where the caller is about to add the derivation: its daemon must be
a goonix daemon."
  (validate-addressing addressing)
  (assert-goonix-daemon store name)
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

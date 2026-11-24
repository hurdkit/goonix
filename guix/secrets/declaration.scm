;;; goonix: data-only vault declarations shared with flake evaluation.
(define-module (guix secrets declaration)
  #:use-module (guix flakes syntax)
  #:use-module (ice-9 match)
  #:use-module (ice-9 regex)
  #:use-module (srfi srfi-1)
  #:export (valid-secret-name?
            read-secret-declarations
            secret-declaration-kind))

(define (valid-secret-name? name)
  "Whether NAME is one safe component shared by vaults and flake references."
  (and (symbol? name)
       (let ((text (symbol->string name)))
         (and (string-match "^[a-zA-Z0-9][a-zA-Z0-9_.-]*$" text)
              (not (string-contains text ".."))
              (not (string-suffix? "." text))))))

(define (secret-declaration-kind declaration)
  "Return the kind of DECLARATION, or #f for a malformed declaration."
  (match declaration
    (((? valid-secret-name?) . properties)
     (match (assq 'kind properties)
       (#f 'file)
       ((_ kind) kind)
       (_ #f)))
    (_ #f)))

(define (read-secret-declarations port)
  "Read the secret names and kinds from a data-only vault form."
  (let ((form (read-data-port port "vault.scm")))
    (match form
      (('vault members ...)
       (unless (equal? '(format 1) (assq 'format members))
         (error "expected a format 1 vault"))
       (match (assq 'secrets members)
         ((_ . declarations)
          (for-each (lambda (declaration)
                      (unless (secret-declaration-kind declaration)
                        (error "invalid secret declaration" declaration)))
                    declarations)
          (map (lambda (declaration)
                 (cons (car declaration)
                       (secret-declaration-kind declaration)))
               declarations))
         (_ (error "vault has no secrets member"))))
      (_ (error "expected a format 1 vault")))))

;;; goonix: transport of signed content-addressing build records.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (guix ca records)
  #:use-module (guix base16)
  #:use-module (guix store)
  #:use-module (ice-9 match)
  #:use-module (rnrs io ports)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:export (build-graph-records
            graph-response
            build-graph-expression
            build-records->expression
            expression->build-records
            expression->graph-choices
            read-graph-expression
            write-graph-fields))

;;; Commentary:
;;;
;;; The HTTP representation is data, not a signature format: (goonix-records
;;; 1 (resolved-hash resolved-drv output path origin relocation signature)
;;; ...).  Resolved hashes are hexadecimal.  Every other field is a string.
;;; Choice hints remain (original-drv output chosen-path) triples throughout
;;; Scheme.  The receiving daemon authenticates signatures against its own
;;; ACL and recomputes R before selecting anything.

(define (records-and-triples fields hints)
  (let loop ((fields fields) (records '()))
    (match fields
      (()
       (values (reverse records)
               (if (zero? (modulo (length hints) 3))
                   (let group ((rest hints) (result '()))
                     (if (null? rest)
                         (reverse result)
                         (group (cdddr rest)
                                (cons (list (car rest) (cadr rest) (caddr rest))
                                      result))))
                   (error "daemon returned incomplete goonix graph hints"
                          hints))))
      ((hash derivation output path origin checked signature . rest)
       (loop rest (cons (list hash derivation output path origin checked
                              signature)
                        records)))
      (_ (error "daemon returned incomplete goonix graph record" fields)))))

(define (graph-response store derivation)
  "Return DERIVATION's signed records and its choice-hint triples."
  (call-with-values (lambda () (query-build-graph store derivation))
    records-and-triples))

(define (build-graph-records store derivation)
  "Return only the signed records of DERIVATION's build graph from STORE."
  (call-with-values (lambda () (graph-response store derivation))
    (lambda (records hints) records)))

(define (build-records->expression records)
  "Return the versioned, portable S-expression for RECORDS."
  `(goonix-records 1 ,@records))

(define (build-graph-expression store derivation)
  "Return DERIVATION's complete signed graph and unsigned choice expression."
  (call-with-values (lambda () (graph-response store derivation))
    (lambda (records hints)
      (append (build-records->expression records)
              `((choices ,hints))))))

(define (record-field? value)
  (and (string? value) (not (string-index value #\nul))))

(define (expression->build-records expression)
  "Validate and return the record lists in EXPRESSION."
  (match expression
    (('goonix-records 1 records ... ('choices (choices ...)))
     (expression->build-records `(goonix-records 1 ,@records)))
    (('goonix-records 1 records ...)
     (for-each
      (match-lambda
        ((hash derivation output path origin checked signature)
         (unless (and (record-field? derivation)
                      (record-field? output)
                      (record-field? path)
                      (record-field? origin)
                      (record-field? signature)
                      (member checked '("0" "1"))
                      (string? hash)
                      (= 64 (string-length hash))
                      (string-every (char-set #\0 #\1 #\2 #\3 #\4 #\5 #\6
                                              #\7 #\8 #\9 #\a #\b #\c #\d
                                              #\e #\f) hash))
           (error "invalid goonix build record" expression)))
        (_ (error "malformed goonix build record" expression)))
      records)
     records)
    (_ (error "unsupported goonix record graph" expression))))

(define (expression->graph-choices expression)
  "Validate and return the unsigned original/output/path choice triples."
  (match expression
    (('goonix-records 1 records ... ('choices (choices ...)))
     (for-each
      (match-lambda
        ((derivation output path)
         (unless (and (record-field? derivation)
                      (record-field? output)
                      (record-field? path))
           (error "invalid goonix graph choice hint" expression)))
        (_ (error "malformed goonix graph choice hint" expression)))
      choices)
     choices)
    (_ (error "missing goonix graph choice hints" expression))))

;;; goonix: the daemon's substituter speaks a bounded hex-line protocol.  The
;;; expression is data only; importGoonixBuildGraph authenticates every record.
(define (read-graph-expression port limit)
  "Read at most LIMIT+1 characters from PORT and parse one graph expression."
  (let ((text (get-string-n port (1+ limit))))
    (when (or (eof-object? text) (> (string-length text) limit))
      (error "goonix graph expression exceeds its size limit"))
    (let ((expression (call-with-input-string text read)))
      (expression->build-records expression)
      (expression->graph-choices expression)
      expression)))

(define (write-graph-fields port records hints)
  "Write the daemon's hex-line graph protocol.  Fields are opaque bytes."
  (define (field value)
    (format port "~a~%" (bytevector->base16-string (string->utf8 value))))
  (display "goonix-records 1\n" port)
  (format port "~a~%" (length records))
  (for-each (lambda (record) (for-each field record)) records)
  (format port "~a~%" (length hints))
  (for-each (lambda (hint) (for-each field hint)) hints)
  (force-output port))

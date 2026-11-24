;;; goonix: inspect content-addressing properties of existing store items.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 7778777 <7778777@7778777.online>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.

(define-module (guix scripts ca)
  #:use-module (guix ui)
  #:use-module (guix scripts)
  #:use-module (guix ca scan)
  #:use-module ((guix store) #:select (%store-prefix))
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-37)
  #:use-module (ice-9 match)
  #:use-module (ice-9 threads)
  #:autoload (json builder) (scm->json-string)
  #:export (guix-ca))

(define (show-help)
  (display (G_ "Usage: guix ca scan [OPTION...] [ITEM...]
Read-only scan of store items for self references.  ITEM names are store
paths or store item names; with no ITEM, scan every directory item.\n"))
  (display (G_ "
      --format=FORMAT    output FORMAT: summary (default) or jsonl
  -j, --jobs=N           scan at most N items concurrently (default: 3)
  -d, --directory=DIR    scan store items below DIR instead of the store
  -h, --help             display this help and exit
  -V, --version          display version information and exit"))
  (newline)
  (show-bug-report-information))

(define %options
  (list (option '(#\h "help") #f #f
                (lambda args
                  (leave-on-EPIPE (show-help))
                  (exit 0)))
        (option '(#\V "version") #f #f
                (lambda args
                  (show-version-and-exit "guix ca")))
        (option '(#\d "directory") #t #f
                (lambda (opt name arg result)
                  (alist-cons 'directory arg result)))
        (option '("format") #t #f
                (lambda (opt name arg result)
                  (alist-cons 'format (string->symbol arg) result)))
        (option '(#\j "jobs") #t #f
                (lambda (opt name arg result)
                  (alist-cons 'jobs (string->number arg) result)))))

(define (report-summary report)
  (format #t "~a files=~a bytes=~a full=~a fragments=~a utf16=~a hidden=~a names=~a links=~a undecodable=~a unsupported=~a~%"
          (scan-report-item report) (scan-report-files report)
          (scan-report-bytes report) (scan-report-full report)
          (scan-report-fragments report) (scan-report-utf16 report)
          (scan-report-hidden report) (scan-report-names report)
          (scan-report-links report) (scan-report-undecodable report)
          (scan-report-unsupported report)))

(define (item-path directory item)
  (if (string-prefix? "/" item)
      item (string-append directory "/" item)))

(define-command (guix-ca . args)
  (category plumbing)
  (synopsis "inspect content-addressing properties of store items")
  (with-error-handling
    (match args
      (("scan" . rest)
       (let* ((opts (parse-command-line rest %options (list '())
                                        #:build-options? #f))
              (directory (or (assoc-ref opts 'directory) (%store-prefix)))
              (output-format (or (assoc-ref opts 'format) 'summary))
              (jobs (or (assoc-ref opts 'jobs) 3))
              (arguments (reverse (filter-map
                                   (match-lambda (('argument . value) value)
                                                 (_ #f)) opts)))
              (items (if (null? arguments)
                         (store-directory-items directory) arguments)))
         (unless (memq output-format '(summary jsonl))
           (leave (G_ "unsupported output format '~a'~%") output-format))
         (unless (and (integer? jobs) (> jobs 0))
           (leave (G_ "invalid job count '~a'~%") jobs))
         (n-for-each-par-map
          jobs
          (lambda (report)
            (if (eq? output-format 'jsonl)
                (format #t "~a~%" (scm->json-string
                                   (scan-report->alist report)))
                (report-summary report)))
          (lambda (item)
            (scan-store-item (item-path directory item)))
          items)))
      (_ (show-help) (exit 1)))))

;;; goonix: content-addressed grafts, applied through upstream's rewriter.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (guix ca build graft)
  #:use-module (guix build graft)
  #:use-module (guix build utils)
  #:use-module (guix build debug-link)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 vlist)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (graft/content-addressed))

;;; Commentary:
;;;
;;; A content-addressed graft writes its own outputs at self-tokens (the
;;; reserved "eout" alphabet), which upstream's rewrite-directory refuses:
;;; it only accepts nix-base32 hashes.  This module applies such a graft
;;; through upstream's exported procedures, in two passes, without copying
;;; their bodies:
;;;
;;;   Pass 1: rewrite-directory with each own-output self-token replaced, in
;;;   the mapping, by a nix-base32 stand-in of the same length derived from
;;;   the token.  Upstream rewrites contents, symlink targets and names.
;;;
;;;   Pass 2: in the output just written, replace each stand-in by its token
;;;   — file contents through upstream's replace-store-references, symlink
;;;   targets likewise, and file names by renaming.  The daemon then
;;;   finalises the tokens to the content addresses.
;;;
;;; This module lives outside guix/build so that no upstream build module
;;; imports it: input-addressed graft derivations stay exactly upstream's.
;;;
;;; Code:

(define %nix-base32-chars
  ;; As in (guix base32): digits and lower case letters except e o t u.
  "0123456789abcdfghijklmnpqrsvwxyz")

(define (token-stand-in token)
  "Return a nix-base32 string of the same length as TOKEN, derived from it:
each reserved-alphabet character maps to a nix-base32 character by its index.
Distinct tokens give distinct stand-ins."
  (string-map (lambda (c)
                (string-ref %nix-base32-chars
                            (or (string-index "eout" c) 0)))
              token))

(define (hash-of-path path)
  "Return the 32-character hash part of the store path PATH."
  (substring (basename path) 0 32))

(define (name-of-path path)
  "Return the name part of the store path PATH."
  (substring (basename path) 33))

(define (store-path-name? file)
  "Whether FILE's basename has the shape of a store path name: 32 hash
characters, a dash, and a name."
  (let ((base (basename file)))
    (and (> (string-length base) 33)
         (char=? #\- (string-ref base 32)))))

(define* (graft/content-addressed old-outputs new-outputs mapping
                                  #:key (log-port (current-output-port)))
  "Apply the grafts described by MAPPING on OLD-OUTPUTS, leading to
NEW-OUTPUTS, where the new outputs are content-addressing self-tokens.
OLD-OUTPUTS and NEW-OUTPUTS are lists of output name/file name pairs; MAPPING
is a list of file name pairs.  See the module commentary for the two passes."
  (define own-outputs
    (match new-outputs
      (((names . files) ...) files)))

  ;; Each own output's token, and its nix-base32 stand-in.
  (define stand-ins
    (map (lambda (output)
           (cons (hash-of-path output)
                 (token-stand-in (hash-of-path output))))
         own-outputs))

  (define (stand-in-for hash)
    (or (assoc-ref stand-ins hash) hash))

  ;; Pass 1: upstream's rewriter, with the own-output tokens stood in by
  ;; nix-base32 strings of the same length.
  (define (stand-in-path path)
    (string-append (%store-directory) "/"
                   (stand-in-for (hash-of-path path))
                   "-" (name-of-path path)))
  (define mapping/stand-in
    (map (match-lambda
           ((origin . replacement)
            (cons origin
                  (if (member replacement own-outputs)
                      (stand-in-path replacement)
                      replacement))))
         mapping))

  ;; Pass 2 helpers: replace each stand-in by its token in the outputs just
  ;; written.  The table maps a stand-in hash to the token hash plus a dash;
  ;; the name that follows the dash in the file is left as it is by
  ;; replace-store-references, which rewrites only the hash+dash pattern.
  (define table
    (alist->vhash
     (map (match-lambda
            ((token . stand-in)
             (cons stand-in (string->utf8 (string-append token "-")))))
          stand-ins)))
  ;; stand-ins is keyed by token; file names after pass 1 carry stand-ins,
  ;; so the rename loop below looks a stand-in up in this reversed alist.
  (define stand-ins-by-stand-in
    (map (match-lambda ((token . stand-in) (cons stand-in token)))
         stand-ins))
  (define (token-for-stand-in hash)
    (assoc-ref stand-ins-by-stand-in hash))
  (define (restore-file file)
    (make-file-writable file)
    (with-atomic-file-replacement file
      (lambda (in out)
        (replace-store-references in out table))))
  (define (restore-symlink file)
    (let ((target (readlink file)))
      (let ((restored
             (call-with-output-string
               (lambda (out)
                 (replace-store-references (open-input-string target)
                                           out table)))))
        (unless (string=? target restored)
          (delete-file file)
          (symlink restored file)))))

  ;; Pass 1: upstream's rewriter, with the own-output tokens stood in.
  (for-each (lambda (input output)
              (format log-port "grafting '~a' -> '~a' (content-addressed)...~%"
                      input output)
              (force-output log-port)
              (rewrite-directory input output mapping/stand-in))
            (match old-outputs
              (((names . files) ...) files))
            own-outputs)

  ;; Pass 2: restore the tokens in contents, symlink targets and names.
  (for-each
   (lambda (output)
     (for-each (lambda (file)
                 (let ((stat (lstat file)))
                   (case (stat:type stat)
                     ((regular) (restore-file file))
                     ((symlink) (restore-symlink file))
                     ((directory) #t)
                     (else #t))))
               (find-files output (const #t) #:directories? #t))
     ;; File names: a directory or file named after a stand-in is renamed
     ;; to the token.  Rename deepest first so parents stay valid.
     (let ((named (filter (lambda (file)
                            (and (store-path-name? file)
                                 (token-for-stand-in (hash-of-path file))))
                         (find-files output (const #t) #:directories? #t))))
       (for-each (lambda (file)
                   (let* ((base (basename file))
                          (token (token-for-stand-in (substring base 0 32)))
                          (target (string-append (dirname file) "/"
                                                 token "-"
                                                 (substring base 33))))
                     (rename-file file target)))
                 (sort named (lambda (a b)
                               (> (string-length a) (string-length b)))))))
   own-outputs)

  ;; Upstream's grafting hooks (debug-link repair) run on the final outputs.
  ;; (guix build graft) defines %graft-hooks but does not export it (only
  ;; replace-store-references, rewrite-directory and graft are exported), so
  ;; the hook list is spelled out here; if upstream exports %graft-hooks
  ;; later, use it so a hook it adds applies to content-addressed grafts too.
  (for-each (lambda (hook)
              (hook old-outputs new-outputs mapping #:log-port log-port))
            (list graft-debug-links)))

;;; graft.scm ends here
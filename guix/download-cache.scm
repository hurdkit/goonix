;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 7778777 <7778777@7778777.online>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (guix download-cache)
  #:use-module (guix base32)
  #:use-module ((guix build utils)
                #:select (strip-store-file-name delete-file-recursively))
  #:use-module ((guix utils) #:select (with-environment-variables))
  #:autoload   (guix build download) (download-method-enabled?
                                      open-socket-for-uri)
  #:autoload   (guix build git) (git-fetch)
  #:use-module (web uri)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (ice-9 match)
  #:export (%download-cache
            download-cache-url
            cache-first

            %download-cache-local-files?
            %download-cache-connection-timeout
            download-cache-git-url
            download-cache-reachable?
            git-fetch/download-cache))

;;; Commentary:
;;;
;;; goonix: a download cache for the daemon's machine.
;;;
;;; The built-in download builder asks the cache for a file before it asks
;;; the file's own URLs.  The cache is named by the GOONIX_DOWNLOAD_CACHE
;;; variable in the daemon's environment, which is the environment of 'guix
;;; perform-download'; without it nothing changes.  The request names the
;;; file by its hash and carries the file's URLs, so that a cache that lacks
;;; the file can fetch and keep it.  The daemon checks the hash of what it
;;; gets, as for any download, so the cache need not be trusted.
;;;
;;; The cache also keeps copies of Git repositories.  The built-in Git
;;; download ('git-fetch/download-cache') and the checkouts of the 'guix'
;;; command ((guix download-cache git)) take objects from the copy before
;;; they ask the repository; the procedures here give a copy's address and
;;; tell whether the cache can be reached at all.
;;; doc/goonix/download-cache.md describes what a cache must serve.
;;;
;;; Code:

(define %download-cache
  ;; Base URL of the cache, or #f.
  (make-parameter (getenv "GOONIX_DOWNLOAD_CACHE")))

(define (fetchable? url)
  "Return true if URL, a string, is one that a cache can fetch."
  (and=> (string->uri url)
         (lambda (uri)
           (memq (uri-scheme uri) '(http https ftp)))))

(define (download-cache-url cache name algo hash origins)
  "Return the URL at which CACHE, the base URL of a download cache, serves
the file NAME whose hash for ALGO is HASH, a bytevector; return #f when ALGO
is not SHA-256.  ORIGINS is the list of URLs that NAME comes from; those the
cache can fetch are passed on."
  (and (eq? algo 'sha256)
       (string-append
        (string-trim-right cache #\/) "/file/" (uri-encode name)
        "/sha256/" (bytevector->nix-base32-string hash)
        (match (filter fetchable? origins)
          (() "")
          (urls (string-append
                 "?" (string-join (map (lambda (url)
                                         (string-append "url=" (uri-encode url)))
                                       urls)
                                  "&")))))))

(define (read-mirrors file)
  "Return the alist of mirrors in FILE, read the way 'guix perform-download'
reads it: FILE comes with the derivation."
  (if file
      ((@@ (guix scripts perform-download) call-with-input-file/no-symlinks)
       file
       (@@ (guix scripts perform-download) read/safe))
      '()))

(define (expand url mirrors)
  "Return the list of URLs that URL stands for: itself, or the mirrors of a
'mirror://' URL according to the alist MIRRORS."
  (match (string->uri url)
    (#f '())
    (uri (map uri->string
              ((@@ (guix build download) maybe-expand-mirrors) uri mirrors)))))

(define (cache-first url output algo hash mirrors)
  "Return URL, a URL or a list of URLs for the download of OUTPUT, preceded
by the address of that file in the download cache when there is one.  ALGO
and HASH are the hash of OUTPUT; MIRRORS is the name of the file of mirrors
that comes with the derivation, or #f."
  (let ((urls  (if (list? url) url (list url)))
        (cache (%download-cache)))
    (match (and cache
                (not (string-null? cache))
                (download-cache-url cache (strip-store-file-name output)
                                    algo hash
                                    (let ((mirrors (read-mirrors mirrors)))
                                      (append-map (cut expand <> mirrors)
                                                  urls))))
      (#f url)
      (first (cons first urls)))))

;;;
;;; Git repositories.
;;;

(define %download-cache-local-files?
  ;; For tests only: also accept a file:// cache, and file:// repositories.
  (make-parameter #f))

(define %download-cache-connection-timeout
  ;; Seconds to wait for a connection to the cache before going without it.
  (make-parameter 3))

(define (download-cache-git-url cache url)
  "Return the URL at which CACHE, the base URL of a download cache or #f,
serves its copy of the Git repository at URL, or #f if it serves none.  The
address is URL with \"://\" written \"/\", below \"/git/\": the copy of
https://example.org/x.git is at CACHE/git/https/example.org/x.git."
  (define schemes
    (if (%download-cache-local-files?) '(http https file) '(http https)))

  (match (and cache (not (string-null? cache))
              (list (string->uri cache) (string->uri url)))
    (((? uri? base) (? uri? origin))
     (let ((scheme (symbol->string (uri-scheme origin))))
       (and (memq (uri-scheme base) schemes)
            (memq (uri-scheme origin) schemes)
            (not (uri-userinfo origin))
            (not (uri-query origin))
            (not (uri-fragment origin))
            (string-prefix? (string-append scheme "://") url)
            (not (any (cut member <> '("." ".."))
                      (string-split (uri-path origin) #\/)))
            (string-append (string-trim-right cache #\/) "/git/" scheme "/"
                           (string-drop url (+ 3 (string-length scheme)))))))
    (_ #f)))

(define download-cache-reachable?
  (let ((answers '()))
    (lambda (cache)
      "Return true if a connection to CACHE, the base URL of a download
cache, can be made within %DOWNLOAD-CACHE-CONNECTION-TIMEOUT seconds.  The
answer is kept for the rest of the process, so that a cache that cannot be
reached costs one wait, not one per repository."
      (match (assoc cache answers)
        ((_ . answer) answer)
        (#f
         (let* ((uri    (string->uri cache))
                (answer (match (and uri (uri-scheme uri))
                          ('file (file-exists? (uri-path uri)))
                          ((or 'http 'https)
                           (false-if-exception
                            (begin
                              (close-port
                               (open-socket-for-uri
                                uri #:timeout
                                (%download-cache-connection-timeout)))
                              #t)))
                          (_ #f))))
           (set! answers (alist-cons cache answer answers))
           answer))))))

(define* (git-fetch/download-cache url commit directory fallback
                                   #:key recursive? (git-command "git"))
  "Check out COMMIT of the Git repository at URL into DIRECTORY from the
download cache's copy of it, when there is a cache that can be reached and
the 'upstream' download method is enabled.  Return true on success.
Otherwise remove what the attempt left in DIRECTORY and return the value of
(FALLBACK), which fetches as without a cache.  Submodules are fetched from
the URLs that the repository records."
  (define mirror
    (download-cache-git-url (%download-cache) url))

  (if (and mirror
           (download-method-enabled? 'upstream)
           (download-cache-reachable? (%download-cache)))
      (or (begin
            (format (current-error-port)
                    "trying the download cache's copy of ~a...~%" url)
            ;; A transfer that stalls is given up rather than waited for.
            (false-if-exception
             (with-environment-variables
                 '(("GIT_HTTP_LOW_SPEED_LIMIT" "1")
                   ("GIT_HTTP_LOW_SPEED_TIME" "60")
                   ("GIT_TERMINAL_PROMPT" "0"))
               (git-fetch mirror commit directory
                          #:recursive? recursive?
                          #:git-command git-command))))
          (begin
            (format (current-error-port)
                    "the download cache does not have it; using ~a~%" url)
            (when (file-exists? directory)
              (delete-file-recursively directory))
            (fallback)))
      (fallback)))

;;; download-cache.scm ends here

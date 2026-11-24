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

;;; goonix: the built-in download asks the download cache first.

(define-module (test-download-cache)
  #:use-module (guix download-cache)
  #:use-module (guix base32)
  #:use-module ((guix download) #:select (url-fetch))
  #:use-module (guix derivations)
  #:use-module (guix monads)
  #:use-module (guix store)
  #:use-module (guix tests)
  #:use-module (guix tests http)
  #:use-module ((guix build utils)
                #:select (call-with-temporary-output-file))
  #:use-module ((gcrypt hash) #:select (sha256))
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-64))

(define %store
  (open-connection-for-tests))

(define content "what the file holds\n")
(define hash (sha256 (string->utf8 content)))
(define base32 (bytevector->nix-base32-string hash))

(define (download url cache)
  "Download the fixed-output file CONTENT from URL with the program that the
daemon runs, 'guix perform-download', in an environment where CACHE, a URL or
#f, is the download cache.  Return what was written, or #f if nothing was."
  (let* ((drv    (run-with-store %store
                   (url-fetch url 'sha256 hash "cached-file.txt")))
         ;; The daemon passes the output's file name in the store; it is ours
         ;; to write in the store of the tests.
         (output (derivation->output-path drv)))
    (dynamic-wind
      (lambda ()
        (if cache
            (setenv "GOONIX_DOWNLOAD_CACHE" cache)
            (unsetenv "GOONIX_DOWNLOAD_CACHE")))
      (lambda ()
        (system* "guix" "perform-download" (derivation-file-name drv) output)
        (and (file-exists? output)
             (call-with-input-file output get-string-all)))
      (lambda ()
        (unsetenv "GOONIX_DOWNLOAD_CACHE")
        (false-if-exception (delete-file output))))))

(define cache-path
  ;; Where the cache must be asked for the file, below its base URL.
  (string-append "/cache/file/cached-file.txt/sha256/" base32))

(test-begin "download-cache")

(test-equal "address of a file in the cache"
  (string-append "http://cache.example/file/hello-1.0.tar.gz/sha256/" base32)
  (download-cache-url "http://cache.example/" "hello-1.0.tar.gz"
                      'sha256 hash '()))

(test-equal "the URLs of the file are passed on, those a cache can fetch"
  (string-append "http://cache.example/base/file/a%2Bb/sha256/" base32
                 "?url=https%3A%2F%2Fone.example%2Fa%2Bb"
                 "&url=ftp%3A%2F%2Ftwo.example%2Fa%2Bb")
  (download-cache-url "http://cache.example/base" "a+b" 'sha256 hash
                      '("https://one.example/a+b"
                        "file:///etc/passwd"
                        "ftp://two.example/a+b")))

(test-equal "no address for another hash algorithm"
  #f
  (download-cache-url "http://cache.example" "x" 'sha512 hash '()))

(test-equal "without a cache the URLs are unchanged"
  '("http://one.example/x" ("http://one.example/x" "http://two.example/x"))
  (parameterize ((%download-cache #f))
    (list (cache-first "http://one.example/x" "/gnu/store/abc-x"
                       'sha256 hash #f)
          (cache-first '("http://one.example/x" "http://two.example/x")
                       "/gnu/store/abc-x" 'sha256 hash #f))))

(test-equal "with a cache its address comes first, mirrors expanded"
  (list (string-append "http://cache.example/file/hello.tar.gz/sha256/" base32
                       "?url=https%3A%2F%2Fone.example%2Fgnu%2Fhello.tar.gz"
                       "&url=http%3A%2F%2Ftwo.example%2Fpub%2Fhello.tar.gz")
        "mirror://test/hello.tar.gz")
  (call-with-temporary-output-file
   (lambda (mirrors port)
     (write '((test "https://one.example/gnu/" "http://two.example/pub/")) port)
     (close-port port)
     (parameterize ((%download-cache "http://cache.example"))
       (cache-first "mirror://test/hello.tar.gz"
                    (string-append (%store-prefix)
                                   "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-hello.tar.gz")
                    'sha256 hash mirrors)))))

;; The server answers only at the paths named here, so a request anywhere
;; else fails the download.

(test-equal "a download is taken from the cache"
  content
  (with-http-server `((,cache-path 200 ,content))
    (download (%local-url #:path "/origin/never-asked")
              (%local-url #:path "/cache"))))

(test-equal "when the cache lacks the file, its own URL is used"
  content
  (with-http-server `((,cache-path 404 "")
                      ("/origin/cached-file.txt" 200 ,content))
    (download (%local-url #:path "/origin/cached-file.txt")
              (%local-url #:path "/cache"))))

(test-equal "without a cache only the file's own URL is asked"
  content
  (with-http-server `(("/origin/cached-file.txt" 200 ,content))
    (download (%local-url #:path "/origin/cached-file.txt") #f)))

(test-end "download-cache")

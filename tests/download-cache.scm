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

;;; goonix: the built-in downloads, of files and of Git checkouts, and the
;;; checkouts of the 'guix' command ask the download cache first.

(define-module (test-download-cache)
  #:use-module (guix download-cache)
  #:use-module (guix base32)
  #:use-module ((guix download) #:select (url-fetch %download-methods))
  #:use-module (guix git-download)
  #:use-module ((guix git)
                #:select (with-repository
                          update-cached-checkout
                          url-cache-directory
                          %repository-cache-directory))
  #:use-module (guix derivations)
  #:use-module (guix monads)
  #:use-module (guix store)
  #:use-module (guix tests)
  #:use-module (guix tests http)
  #:use-module (guix tests git)
  #:use-module ((guix utils)
                #:select (with-environment-variables
                          call-with-temporary-directory))
  #:use-module ((guix build utils)
                #:select (call-with-temporary-output-file mkdir-p invoke))
  #:use-module (git)
  #:use-module ((gcrypt hash) #:select (sha256))
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-26)
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

;;;
;;; Git repositories: their address in the cache.
;;;

(define (unused-port)
  "Return a TCP port of the loopback interface that nothing listens on."
  (let ((sock (socket PF_INET SOCK_STREAM 0)))
    (bind sock AF_INET INADDR_LOOPBACK 0)
    (let ((port (sockaddr:port (getsockname sock))))
      (close-port sock)
      port)))

(define (unreachable-url path)
  "Return an HTTP URL ending in PATH on a port where nothing listens."
  (string-append "http://127.0.0.1:" (number->string (unused-port)) path))

(test-equal "address of a Git repository in the cache"
  "http://cache.example:8480/git/https/git.savannah.gnu.org/git/sed.git"
  (download-cache-git-url "http://cache.example:8480/"
                          "https://git.savannah.gnu.org/git/sed.git"))

(test-equal "no address for a repository that a cache does not serve"
  '(#f #f #f #f #f #f #f #f #f)
  (map (lambda (cache url)
         (download-cache-git-url cache url))
       '(#f "" "http://cache.example" "http://cache.example"
         "http://cache.example" "http://cache.example" "http://cache.example"
         "file:///srv/cache" "http://cache.example")
       '("https://example.org/r.git" "https://example.org/r.git"
         "git://example.org/r.git" "https://user@example.org/r.git"
         "https://example.org/r.git?x=y" "https://example.org/a/../r.git"
         "ssh://example.org/r.git" "https://example.org/r.git"
         "file:///srv/r.git")))

(test-equal "a file cache and file repositories, for tests only"
  "file:///srv/cache/git/file//srv/r.git"
  (parameterize ((%download-cache-local-files? #t))
    (download-cache-git-url "file:///srv/cache" "file:///srv/r.git")))

(test-equal "a cache that cannot be reached is found out, once a process"
  '(#f #f)
  (let* ((port  (unused-port))
         (cache (string-append "http://127.0.0.1:" (number->string port))))
    (let ((first (download-cache-reachable? cache))
          (sock  (socket PF_INET SOCK_STREAM 0)))
      ;; Something listens there now, but the answer kept is the first.
      (setsockopt sock SOL_SOCKET SO_REUSEADDR 1)
      (bind sock AF_INET INADDR_LOOPBACK port)
      (listen sock 1)
      (let ((second (download-cache-reachable? cache)))
        (close-port sock)
        (list first second)))))

(test-assert "a cache that listens can be reached"
  (let ((sock (socket PF_INET SOCK_STREAM 0)))
    (bind sock AF_INET INADDR_LOOPBACK 0)
    (listen sock 1)
    (let ((answer (download-cache-reachable?
                   (string-append "http://127.0.0.1:"
                                  (number->string
                                   (sockaddr:port (getsockname sock)))))))
      (close-port sock)
      answer)))

(test-assert "derivations are the same with and without a cache"
  (let ((git   (lambda ()
                 (derivation-file-name
                  (run-with-store %store
                    (git-fetch (git-reference
                                (url "https://example.org/r.git")
                                (commit "v1.0"))
                               'sha256 hash "r-checkout")))))
        (plain (lambda ()
                 (derivation-file-name
                  (run-with-store %store
                    (url-fetch "https://example.org/r.tar.gz" 'sha256 hash
                               "r.tar.gz"))))))
    (let ((without (list (git) (plain)))
          (with    (with-environment-variables
                       '(("GOONIX_DOWNLOAD_CACHE" "http://cache.example"))
                     (parameterize ((%download-cache "http://cache.example"))
                       (list (git) (plain))))))
      (equal? without with))))

;;;
;;; The built-in Git download.
;;;

(define-syntax-rule (with-cache cache body ...)
  "Evaluate BODY with CACHE, a URL, as the download cache; a file:// URL is
accepted there, as are file:// repositories."
  (parameterize ((%download-cache cache)
                 (%download-cache-local-files? #t))
    body ...))

(define (copy-in-cache cache url repository)
  "Put a bare clone of REPOSITORY where CACHE, a directory, keeps its copy of
the repository at URL: below git/, URL with \"://\" written \"/\"."
  (let* ((scheme (string-take url (string-index url #\:)))
         (rest   (string-drop url (+ 3 (string-length scheme))))
         (copy   (string-append cache "/git/" scheme "/" rest)))
    (mkdir-p (dirname copy))
    (invoke (git-command) "clone" "--quiet" "--bare" repository copy)
    copy))

(define (head-commit directory)
  (with-repository directory repository
    (oid->string (reference-target (repository-head repository)))))

(define (perform-git-download* drv output)
  "Run the procedure that 'guix perform-download' runs for DRV, a
builtin:git-download derivation, writing to OUTPUT; return the names of the
files in OUTPUT, or #f if there is none."
  (with-environment-variables `(("PATH" ,(getenv "PATH")))
    ((@@ (guix scripts perform-download) perform-git-download) drv output))
  (and (file-exists? output)
       (sort (scandir output (negate (cut member <> '("." ".."))))
             string<?)))

(define (git-download-derivation url commit)
  (parameterize ((%download-methods '(upstream)))
    (run-with-store %store
      (git-fetch (git-reference (url url) (commit commit))
                 'sha256 hash "cached-checkout"))))

(unless (member "git-download" (built-in-builders %store))
  (test-skip 1))
(test-equal "built-in Git download: the commit comes from the cache's copy"
  '("README" "doc")
  ;; The repository itself cannot be reached.
  (with-temporary-git-repository directory
      '((add "README" "Hello.")
        (add "doc/notes" "Notes.")
        (commit "First"))
    (call-with-temporary-directory
     (lambda (tmp)
       (let ((origin (unreachable-url "/project.git"))
             (cache  (string-append tmp "/cache")))
         (copy-in-cache cache origin directory)
         (with-cache (string-append "file://" cache)
           (perform-git-download* (git-download-derivation
                                   origin (head-commit directory))
                                  (string-append tmp "/out"))))))))

(test-equal "built-in Git download: without the cache's copy, from scratch"
  '(fallback #f)
  ;; The cache has no copy: the usual download runs on an empty output.
  (call-with-temporary-directory
   (lambda (tmp)
     (let ((output (string-append tmp "/out"))
           (seen   'not-called))
       (with-cache (string-append "file://" tmp)
         (let ((result (git-fetch/download-cache
                        (unreachable-url "/project.git")
                        "0123456789abcdef0123456789abcdef01234567" output
                        (lambda ()
                          (set! seen (file-exists? output))
                          'fallback)
                        #:git-command (git-command))))
           (list result seen)))))))

(test-equal "built-in Git download: a cache that cannot be reached"
  '(fallback #f)
  (let ((cache (unreachable-url "")))
    (with-cache cache
      (list (git-fetch/download-cache "https://example.org/project.git"
                                      "v1.0" "/nonexistent/output"
                                      (const 'fallback))
            (download-cache-reachable? cache)))))

;;;
;;; The client's Git checkouts.
;;;

(define (cached-checkout url ref checkouts)
  "Update the checkout of URL to REF below CHECKOUTS, as 'guix pull' and
'guix style' do.  Return the checkout's directory, its commit, and the URL of
its remote \"origin\"."
  (parameterize ((%repository-cache-directory checkouts))
    (let-values (((directory commit _) (update-cached-checkout url #:ref ref)))
      (list directory commit
            (with-repository directory repository
              (remote-url (remote-lookup repository "origin")))))))

(define (file-contains? file text)
  (and (string-contains (call-with-input-file file get-string-all) text) #t))

(test-assert "checkout: cloned from the cache's copy, repository unreachable"
  (with-temporary-git-repository directory
      '((add "README" "Hello.")
        (commit "First")
        (tag "v1.0" "Release."))
    (call-with-temporary-directory
     (lambda (tmp)
       (let ((origin    (unreachable-url "/project.git"))
             (cache     (string-append tmp "/cache"))
             (checkouts (string-append tmp "/checkouts")))
         (copy-in-cache cache origin directory)
         (match (with-cache (string-append "file://" cache)
                  (cached-checkout origin '(tag-or-commit . "v1.0") checkouts))
           ((checkout-directory commit remote)
            (and (string=? commit (head-commit directory))
                 ;; What is recorded names the repository, not the cache.
                 (string=? checkout-directory
                           (url-cache-directory origin checkouts))
                 (string=? remote origin)
                 (not (file-contains? (string-append checkout-directory
                                                     "/.git/config")
                                      cache))))))))))

(test-assert "checkout: a branch, the repository unreachable after the copy"
  ;; The remote's HEAD is asked for: the repository is asked after the
  ;; copy, fails, and what the copy gave is used.
  (with-temporary-git-repository directory
      '((add "README" "Hello.")
        (commit "First"))
    (call-with-temporary-directory
     (lambda (tmp)
       (let ((origin (unreachable-url "/project.git"))
             (cache  (string-append tmp "/cache")))
         (copy-in-cache cache origin directory)
         (match (with-cache (string-append "file://" cache)
                  (cached-checkout origin '() (string-append tmp "/checkouts")))
           ((_ commit remote)
            (and (string=? commit (head-commit directory))
                 (string=? remote origin)))))))))

(test-equal "checkout: an existing one asks the copy, then the repository"
  '(#t #t)
  (with-temporary-git-repository directory
      '((add "README" "Hello.")
        (commit "First"))
    (call-with-temporary-directory
     (lambda (tmp)
       (let* ((origin    (string-append "file://" directory))
              (cache     (string-append tmp "/cache"))
              (checkouts (string-append tmp "/checkouts"))
              (tag       "refs/tags/only-in-the-copy")
              (first     (cached-checkout origin '() checkouts))
              (copy      (copy-in-cache cache origin directory)))
         ;; The copy has a tag that the repository does not have.
         (invoke (git-command) "-C" copy "update-ref" tag "HEAD")
         (match (with-cache (string-append "file://" cache)
                  (cached-checkout origin '() checkouts))
           ((checkout-directory commit remote)
            (list (string=? commit (head-commit directory))
                  (with-repository checkout-directory repository
                    (->bool (false-if-exception
                             (reference-lookup repository tag))))))))))))

(test-equal "checkout: the cache has no copy, so the repository is cloned"
  '(#t #t)
  (with-temporary-git-repository directory
      '((add "README" "Hello.")
        (commit "First"))
    (call-with-temporary-directory
     (lambda (tmp)
       (let ((origin (string-append "file://" directory)))
         (mkdir-p (string-append tmp "/cache"))
         (match (with-cache (string-append "file://" tmp "/cache")
                  (cached-checkout origin '() (string-append tmp "/checkouts")))
           ((_ commit remote)
            (list (string=? commit (head-commit directory))
                  (string=? remote origin)))))))))

(test-equal "checkout: a cache that cannot be reached"
  '(#t #f)
  (with-temporary-git-repository directory
      '((add "README" "Hello.")
        (commit "First"))
    (call-with-temporary-directory
     (lambda (tmp)
       (let ((origin (string-append "file://" directory))
             (cache  (unreachable-url "")))
         (match (with-cache cache
                  (cached-checkout origin '() (string-append tmp "/checkouts")))
           ((_ commit remote)
            (list (string=? commit (head-commit directory))
                  (download-cache-reachable? cache)))))))))

(test-end "download-cache")

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

(define-module (guix download-cache git)
  #:use-module (git)
  #:use-module (guix download-cache)
  #:use-module ((guix build utils) #:select (mkdir-p delete-file-recursively))
  #:use-module ((guix diagnostics) #:select (warning))
  #:use-module (guix i18n)
  #:export (update-from-download-cache
            call-with-download-cache-fallback))

;;; Commentary:
;;;
;;; goonix: the client's Git checkouts (guix/git.scm) take objects from the
;;; download cache's copy of a repository before they ask the repository.
;;;
;;; The copy is only a source of objects.  A checkout made from it records
;;; the repository's own URL as its remote "origin", under the cache
;;; directory named after that URL, and the repository is asked afterwards
;;; as it would be without a cache.  What is checked out goes through the
;;; same commit checks and channel authentication.
;;;
;;; Code:

(define %refspecs
  ;; What a fetch from the copy updates: what a fetch from "origin" would.
  '("+refs/heads/*:refs/remotes/origin/*"
    "+refs/tags/*:refs/tags/*"))

(define* (update-from-download-cache url directory ref
                                     #:key fetch-options available?
                                     (refspecs '()))
  "When the download cache has a copy of the Git repository at URL and can
be reached, take from it what the checkout in DIRECTORY needs for REF: clone
it into DIRECTORY when there is no checkout there, recording URL as the
remote \"origin\", or else fetch from it unless (AVAILABLE? REPOSITORY REF)
says that REF is there already.  REFSPECS are fetched in addition to the
branches and tags.  Return true if the copy was used, false otherwise; on
failure nothing is left that was not there before."
  (define mirror
    (download-cache-git-url (%download-cache) url))

  (define existed?
    (file-exists? directory))

  (and mirror
       (download-cache-reachable? (%download-cache))
       (catch 'git-error
         (lambda ()
           (if (openable-repository? directory)
               (let* ((repository (repository-open directory))
                      (fetched?
                       (and (not (available? repository ref))
                            (begin
                              (remote-fetch
                               (remote-create-anonymous repository mirror)
                               #:fetch-options fetch-options
                               #:refspecs (append %refspecs refspecs))
                              #t))))
                 (repository-close! repository)
                 fetched?)
               (begin
                 (mkdir-p (dirname directory))
                 (let ((repository
                        (clone mirror directory
                               (make-clone-options
                                #:fetch-options fetch-options))))
                   (remote-set-url! repository "origin" url)
                   (repository-close! repository)
                   #t))))
         (lambda (key error . rest)
           (unless existed?
             (when (file-exists? directory)
               (delete-file-recursively directory)))
           #f))))

(define (call-with-download-cache-fallback mirrored? url thunk)
  "Call THUNK, which fetches from the Git repository at URL.  When MIRRORED?
is true, the download cache's copy has been fetched already: if THUNK fails
with a Git error, warn and return #f, so that what the copy gave is used."
  (if mirrored?
      (catch 'git-error
        thunk
        (lambda (key error . rest)
          (warning (G_ "~a: ~a; using the download cache's copy~%")
                   url (git-error-message error))
          #f))
      (thunk)))

;;; git.scm ends here

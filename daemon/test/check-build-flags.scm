;;; GNU Guix --- Functional package management for GNU
;;; This file is part of GNU Guix and is distributed under GPL-3.0-or-later.

;; Keep the direct build and Cabal build on the same language and warnings.
(use-modules (ice-9 match) (ice-9 textual-ports))

(match (command-line)
  ((_ cabal-file make-file)
   (let ((cabal (call-with-input-file cabal-file get-string-all))
         (make (call-with-input-file make-file get-string-all)))
     (for-each
      (lambda (feature)
        (unless (and (string-contains cabal feature)
                     (string-contains make feature))
          (error "Cabal and direct-build flags differ" feature)))
      '("GHC2024" "StrictData" "-Wall" "-Wcompat" "-Widentities"
        "-Wredundant-constraints" "-threaded" "-with-rtsopts=-N"))))
  (_ (error "usage: check-build-flags.scm CABAL-FILE MAKE-FILE")))

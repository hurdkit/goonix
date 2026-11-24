;;; goonix: CA-7 file-level substitution fixture.  Builds V1 (three files) and
;;; V2 (one file changed) in the server store with shell-script derivations
;;; (an interned shell, no bootstrap Guile), writes their names to a file.
(use-modules (guix) (guix tests) (guix store) (guix derivations) (guix gexp)
             (guix monads) (gnu packages bootstrap)
             (ice-9 match) (srfi srfi-1))

(define store (open-connection))
(%graft? #f)
(define shell-source (getenv "GOONIX_SHELL_SOURCE"))
(define shell (add-to-store store "ca-files-shell" #t "sha256" shell-source))
(define mkdir-source (getenv "GOONIX_MKDIR_SOURCE"))
(define mkdir-path (add-to-store store "ca-files-mkdir" #t "sha256" mkdir-source))
(define guile-drv (package-derivation store %bootstrap-guile))
(build-derivations store (list guile-drv))

;; Each file's content is a short tag padded past the daemon's deduplication
;; minimum size (8192 bytes), so the daemon hard-links it into .links and a
;; later item sharing the file fetches nothing for it.
(define (pad tag)
  (string-append tag (make-string (- 9000 (string-length tag)) #\x)))

(define (item name a b c)
  (let ((script (format #f "'~a' \"$out\"; printf '%s' '~a' > \"$out/a\"; printf '%s' '~a' > \"$out/b\"; printf '%s' '~a' > \"$out/c\""
                        mkdir-path (pad a) (pad b) (pad c))))
    (derivation store name shell `("-c" ,script)
                #:sources (list shell mkdir-path)
                #:addressing 'input)))

(define v1 (item "ca-files-v1" "alpha" "beta" "gamma"))
(build-derivations store (list v1))
;; V2 changes only file "b".
(define v2 (item "ca-files-v2" "alpha" "BETA-CHANGED" "gamma"))
(build-derivations store (list v2))
;; V3 is for the corrupt-cache fallback test: the server serves wrong bytes for
;; one of its files, so the file-level NAR hash differs and the substituter must
;; fall back to the (correct) NAR.
(define v3 (item "ca-files-v3" "delta" "epsilon" "zeta"))
(build-derivations store (list v3))

;; A store item that IS a symlink to a directory holding a secret.  A builder
;; can write (symlink "/etc" out); /goonix/file must not walk through it.
;; Added directly with add-to-store (recursive, preserves the symlink) since
;; the pure build environment has no 'ln'.
(define secret-dir (getenv "GOONIX_SECRET_DIR"))
(define symlink-source (string-append (getenv "GOONIX_ASYNC_ROOT") "/symlink-src"))
(symlink secret-dir symlink-source)
(define symlink-item-path
  (add-to-store store "ca-files-symlink-item" #t "sha256" symlink-source))

;; A normal item with a symlink AND a file whose name contains a space.  The
;; file-level path must substitute it file by file (the symlink from its carried
;; target, the space-name file percent-encoded) and the result must be valid.
;; Built as a gexp derivation (bootstrap Guile has 'symlink') so it is a
;; derivation OUTPUT the client substitutes, not a path added locally.
(define (mixed-item)
  (run-with-store store
    (gexp->derivation "ca-files-mixed"
      #~(begin
          (mkdir #$output)
          (call-with-output-file (string-append #$output "/a file")
            (lambda (p) (display #$(pad "space") p)))
          (call-with-output-file (string-append #$output "/plain")
            (lambda (p) (display #$(pad "plain") p)))
          (symlink "a file" (string-append #$output "/link")))
      #:addressing 'input
      #:guile-for-build guile-drv)))
(define mixed-drv (mixed-item))
(build-derivations store (list mixed-drv))
(define mixed-item-path (derivation->output-path mixed-drv))

(define out (match (command-line) ((_ file) file)))
(call-with-output-file out
  (lambda (port)
    (write (list (list 'v1-name (basename (derivation->output-path v1)))
                 (list 'v2-name (basename (derivation->output-path v2)))
                 (list 'v3-name (basename (derivation->output-path v3)))
                 (list 'v1-output (derivation->output-path v1))
                 (list 'v2-output (derivation->output-path v2))
                 (list 'symlink-name (basename symlink-item-path))
                 (list 'mixed-name (basename mixed-item-path))
                 (list 'mixed-output mixed-item-path))
           port)
    (newline port)))
(close-connection store)
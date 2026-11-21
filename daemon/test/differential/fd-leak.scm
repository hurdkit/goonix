;; Regression: writing store items must not leak file descriptors.
;; writeBytes opened each store path write-only and closed it only on exception
;; (bracketOnError), so every successful add-text-to-store leaked one descriptor.
;; Under a low descriptor limit (the runner starts the daemon with
;; prlimit --nofile=64:64), writing more items than the limit exhausts the
;; daemon's descriptor table and the next operation fails with EMFILE
;; ("openFdAt: resource exhausted (Too many open files)").  With the fix
;; (bracket, closing on success too) the descriptor count stays flat and every
;; call succeeds.  The runner asserts the daemon's /proc/PID/fd count after the
;; loop is close to its count before; this file asserts every call succeeds and
;; a trivial derivation still builds afterwards.
(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap) (ice-9 textual-ports) (srfi srfi-1))

(define (assert condition message)
  (unless condition (error message)))

(define fixture (getenv "HS_FD_FIXTURE"))
(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options store #:use-substitutes? #f #:offload? #f)
(%graft? #f)

;; Write many distinct items through ONE connection.  Each add-text-to-store
;; makes the daemon write a store path (writeBytes).  200 > the 64 limit, so a
;; per-write leak exhausts the table well before the loop ends.
(define count 200)
(define paths
  (map (lambda (i)
         (add-text-to-store store
                            (string-append "fd-leak-item-" (number->string i))
                            (string-append "distinct content " (number->string i) "\n")))
       (iota count)))
(assert (= count (length paths)) "not every add-text-to-store returned a path")
(assert (= count (length (delete-duplicates paths)))
        "add-text-to-store returned duplicate paths")
;; Every item must be registered valid (the write completed, not just queued).
(for-each (lambda (path)
            (assert (valid-path? store path)
                    (string-append "item not valid after write: " path)))
          paths)

;; A trivial derivation must still build after the loop: on a leaked daemon the
;; descriptor table is exhausted and the build fails with EMFILE.
(define shell (add-to-store store "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))
(define script
  (add-text-to-store store "fd-leak-builder.sh"
    "printf 'ok\\n' > \"$out\"\n"))
(define drv
  (derivation store "fd-leak-trivial" shell (list "-e" script)
              #:sources (list shell script)))
(build-derivations store (list drv))
(assert (valid-path? store (derivation->output-path drv))
        "trivial derivation did not build after the write loop")
(assert (string=? "ok\n"
                  (call-with-input-file (derivation->output-path drv) get-string-all))
        "trivial derivation output is wrong")
(close-connection store)
(display "fd-leak write-loop: PASS\n")
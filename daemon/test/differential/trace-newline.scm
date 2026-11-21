;; Regression: the daemon's "@ build-started" trace line must be newline-
;; terminated, as C++ printMsg_ appends "\n" to every trace message (util.cc).
;;
;; The client's build-event-output-port (guix/status.scm) splits the build
;; output on newlines and drops the trailing one before tokenizing.  Without
;; the newline, a "@ build-started ... <pid>" line runs into the following
;; "@ build-log <pid> <len>" header: the pid token becomes "<pid>@" and
;; string->number returns #f, so the build is recorded with id #f and the next
;; build-started is swallowed into the misparsed build-log byte count.  The
;; client's update-build then crashes on a missing build id (guix-pack.sh).
;;
;; Build a derivation with print-build-trace on and capture the raw build
;; output; assert the "@ build-started" line is present, ends with a newline,
;; and its last token is a numeric pid.
(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap) (ice-9 textual-ports) (srfi srfi-1) (srfi srfi-13))

(define (assert condition message)
  (unless condition (error message)))

(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options store #:use-substitutes? #f #:print-build-trace #t #:verbosity 1)
(%graft? #f)
(define shell (add-to-store store "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))
(define script
  (add-text-to-store store "trace-builder.sh" "printf 'ok\\n' > \"$out\"\n"))
(define drv
  (derivation store "trace-newline" shell (list "-e" script)
              #:sources (list shell script)))
(define raw
  (call-with-output-string
    (lambda (port)
      (parameterize ((current-build-output-port port))
        (build-derivations store (list drv))))))
;; Find the "@ build-started" line for our derivation in the raw output.
(define lines (string-split raw #\newline))
(define started
  (find (lambda (l) (and (string-prefix? "@ build-started " l)
                         (string-contains l (derivation-file-name drv))))
        lines))
(assert started "no @ build-started line captured for the derivation")
;; The line must be followed by a newline in the raw stream (i.e. it is a
;; complete line, not glued to the next "@ build-log" header).
(assert (string-contains raw (string-append started "\n"))
        (string-append "@ build-started line is not newline-terminated: "
                       (format #f "~s" started)))
;; The last token must be a numeric pid (not "<pid>@" from a glued header).
(define pid-token (last (string-tokenize started)))
(assert (string->number pid-token)
        (string-append "build-started pid token is not numeric: " pid-token))
(close-connection store)
(display "build-started newline-terminated: PASS\n")
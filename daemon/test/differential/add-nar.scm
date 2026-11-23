;; Drive wopAddToStore through the REAL daemon over the socket and print, for
;; each case, the resulting store path, the mode of the file on disk, the NAR
;; hash and size the daemon registered, and whether it is valid.
;;
;; Two properties of the C++ handler are easy to lose in a port:
;;
;;  1. RetrieveRegularNARSink (nix-daemon.cc) does not override isExecutable(),
;;     which is a no-op in ParseSink.  For recursive? = #f the daemon writes the
;;     CONTENTS with writeFile (mode 0666 & ~umask) and then canonicalises, so
;;     the NAR's executable bit is DROPPED: the stored file ends up 0444.
;;     A port that honours the NAR's executable flag produces 0555 and a
;;     different narHash for the same input.
;;
;;  2. The compatibility hack: when the obsolete `fixed' field is not 1, C++
;;     forces BOTH hashAlgo = sha256 AND recursive = true.  Forcing only the
;;     algorithm leaves recursive = #f and changes the path.
;;
;; The client sends `fixed' = 1 always (see guix/store.scm add-to-store), so
;; case 2 is driven by a raw frame instead.
(use-modules (guix store) (guix base32) (guix serialization) (ice-9 binary-ports)
             (ice-9 ftw) (rnrs bytevectors))

(define fixture (getenv "ADD_NAR_FIXTURE"))

;; process-stderr is internal to (guix store); take it from there rather than
;; re-implementing the stderr framing.
(define process-stderr
  (module-ref (resolve-module (quote (guix store))) (quote process-stderr)))

(define (mode-of path)
  (logand (stat:mode (lstat path)) #o7777))

(define (report label store path)
  (let ((info (query-path-info store path)))
    (format #t "~a path=~a mode=~o narhash=~a narsize=~a valid=~a\n"
            label
            (basename path)
            (mode-of path)
            (bytevector->nix-base32-string (path-info-hash info))
            (path-info-nar-size info)
            (valid-path? store path))))

;; Source files live OUTSIDE the store, per case, so nothing is shared.
(define (make-source name executable?)
  (let ((p (string-append fixture "/src-" name)))
    (call-with-output-file p (lambda (port) (display "hello\n" port)))
    (chmod p (if executable? #o755 #o644))
    p))

(let ((store (open-connection (getenv "GUIX_DAEMON_SOCKET"))))
  ;; recursive? = #f, executable source: does the exec bit survive?
  (let* ((src (make-source "flat-exec" #t))
         (path (add-to-store store "flat-exec" #f "sha256" src)))
    (report "flat-exec" store path))
  ;; recursive? = #f, non-executable source: the control.
  (let* ((src (make-source "flat-plain" #f))
         (path (add-to-store store "flat-plain" #f "sha256" src)))
    (report "flat-plain" store path))
  ;; recursive? = #t on a regular file: restorePath honours the NAR bit, so
  ;; this one MUST be executable on both sides.
  (let* ((src (make-source "rec-exec" #t))
         (path (add-to-store store "rec-exec" #t "sha256" src)))
    (report "rec-exec" store path))
  (let* ((src (make-source "rec-plain" #f))
         (path (add-to-store store "rec-plain" #t "sha256" src)))
    (report "rec-plain" store path))
  ;; A non-sha256 algorithm, non-recursive: narHash must be recomputed over the
  ;; NAR of the STORED path, not taken from the declared digest.
  (let* ((src (make-source "flat-sha1" #t))
         (path (add-to-store store "flat-sha1" #f "sha1" src)))
    (report "flat-sha1" store path))
  ;; A directory, recursive: a symlink and a nested executable inside.
  (let ((dir (string-append fixture "/src-tree")))
    (mkdir dir)
    (call-with-output-file (string-append dir "/a") (lambda (p) (display "a\n" p)))
    (chmod (string-append dir "/a") #o755)
    (symlink "a" (string-append dir "/link"))
    (let ((path (add-to-store store "tree" #t "sha256" dir)))
      (report "tree" store path)
      (format #t "tree-a-mode=~o tree-link=~a\n"
              (mode-of (string-append path "/a"))
              (readlink (string-append path "/link")))))
  ;; The compatibility hack.  guix/store.scm always sends `fixed' = 1, so drive
  ;; a RAW frame with fixed = 0 and recursive? = #f.  C++ then forces BOTH
  ;; sha256 AND recursive = true, so the result must equal the recursive sha256
  ;; addition of the same file (rec-exec above), executable bit included.
  (let* ((src (make-source "compat-exec" #t))
         (port (store-connection-socket store)))
    (write-value integer 7 port)          ; wopAddToStore
    (write-value utf8-string "rec-exec" port)
    (write-value integer 0 port)          ; obsolete `fixed' = 0
    (write-value boolean #f port)         ; recursive? = #f, to be overridden
    (write-value utf8-string "sha1" port) ; algorithm, to be overridden
    (write-file src port)
    (force-output port)
    (let loop ((done? (process-stderr store)))
      (or done? (loop (process-stderr store))))
    (let ((path (read-value store-path port)))
      (report "compat-fixed0" store path)))
  (close-connection store))
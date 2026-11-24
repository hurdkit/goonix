;;; goonix: CA-7 file-level substitution client (real guix build).  Builds V1
;;; then V2 through the client daemon with --substitute-urls pointing at the
;;; server; the daemon's substituter assembles each item from its files
;;; (hard-linking .links, fetching the rest).  The server's request log is the
;;; gate's evidence: three /goonix/file for V1, one for V2, no NAR for V2.
(use-modules (guix) (guix tests) (guix store) (guix derivations) (guix gexp)
             (guix monads) (gnu packages bootstrap)
             ((guix build utils) #:select (mkdir-p))
             (ice-9 match) (ice-9 ftw) (ice-9 textual-ports) (srfi srfi-1))

(define store (open-connection))
(%graft? #f)
(define shell-source (getenv "GOONIX_SHELL_SOURCE"))
(define shell (add-to-store store "ca-files-shell" #t "sha256" shell-source))
(define mkdir-source (getenv "GOONIX_MKDIR_SOURCE"))
(define mkdir-path (add-to-store store "ca-files-mkdir" #t "sha256" mkdir-source))
(define guile-drv (package-derivation store %bootstrap-guile))
(build-derivations store (list guile-drv))

;; The SAME derivations the server built (same name, builder, args, sources,
;; input addressing), so their output paths match and the daemon substitutes
;; them from the server rather than building locally.  Content is padded past
;; the daemon's deduplication minimum (8192 bytes) so shared files hard-link.
(define (pad tag)
  (string-append tag (make-string (- 9000 (string-length tag)) #\x)))

(define (item name a b c)
  (let ((script (format #f "'~a' \"$out\"; printf '%s' '~a' > \"$out/a\"; printf '%s' '~a' > \"$out/b\"; printf '%s' '~a' > \"$out/c\""
                        mkdir-path (pad a) (pad b) (pad c))))
    (derivation store name shell `("-c" ,script)
                #:sources (list shell mkdir-path)
                #:addressing 'input)))

(match (command-line)
  ((_ fixture-file root)
   (let* ((data (call-with-input-file fixture-file read))
          (field (lambda (name) (cadr (assq name data))))
          (v1-name (field 'v1-name))
          (v2-name (field 'v2-name))
          (v1 (item "ca-files-v1" "alpha" "beta" "gamma"))
          (v2 (item "ca-files-v2" "alpha" "BETA-CHANGED" "gamma")))
     ;; Sanity: the client's derivations match the server's output paths.
     (unless (and (string=? v1-name (basename (derivation->output-path v1)))
                  (string=? v2-name (basename (derivation->output-path v2))))
       (error "client derivation names differ from server"
              v1-name (derivation->output-path v1)
              v2-name (derivation->output-path v2)))
     ;; Real builds through the daemon; substitution is enabled by the
     ;; daemon's --substitute-urls.  V1 fetches three files; V2 (one file
     ;; changed) fetches one, the rest hard-linked from .links.
     (build-derivations store (list v1))
     (build-derivations store (list v2))
     ;; Both outputs are valid in the client store.
     (unless (and (valid-path? store (derivation->output-path v1))
                  (valid-path? store (derivation->output-path v2)))
       (error "V1/V2 not valid in client store"))
     ;; The changed content is present in V2 (padded past the dedup minimum).
     (unless (string=? (pad "BETA-CHANGED")
                       (call-with-input-file
                           (string-append (derivation->output-path v2) "/b")
                         get-string-all))
       (error "V2 file b content wrong"))
     ;; The mixed item (a symlink + a file whose name contains a space) is
     ;; substituted file by file.  Build the SAME gexp derivation the server
     ;; built (matching output path), so the daemon substitutes it from the
     ;; server rather than building locally.
     (let* ((mixed-name (field 'mixed-name))
            (mixed-drv
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
                 #:guile-for-build guile-drv))))
       (unless (string=? mixed-name (basename (derivation->output-path mixed-drv)))
         (error "mixed item path differs from server"
                mixed-name (derivation->output-path mixed-drv)))
       (build-derivations store (list mixed-drv))
       (let ((path (derivation->output-path mixed-drv)))
         (unless (valid-path? store path)
           (error "mixed item not valid in client store"))
         ;; The symlink and the space-name file are present and correct.
         (unless (and (eq? 'symlink (stat:type (lstat (string-append path "/link"))))
                      (string=? "a file" (readlink (string-append path "/link")))
                      (string=? (pad "space")
                                (call-with-input-file (string-append path "/a file")
                                  get-string-all)))
           (error "mixed item content wrong"))))
     (call-with-output-file (string-append root "/result")
       (lambda (port)
         (format port "BUILD_OK=1~%")))))
  ;; V3-only mode: build just V3 (for the corrupt-cache fallback test).  The
  ;; server serves wrong bytes for one of V3's files, so the file-level NAR hash
  ;; differs and the substituter must fall back to the (correct) NAR.
  ((_ fixture-file root "v3")
   (let* ((data (call-with-input-file fixture-file read))
          (field (lambda (name) (cadr (assq name data))))
          (v3-name (field 'v3-name))
          (v3 (item "ca-files-v3" "delta" "epsilon" "zeta")))
     (unless (string=? v3-name (basename (derivation->output-path v3)))
       (error "client v3 name differs from server"
              v3-name (derivation->output-path v3)))
     (build-derivations store (list v3))
     (let ((path (derivation->output-path v3)))
       (unless (valid-path? store path)
         (error "v3 not valid in client store"))
       ;; The CORRECT content is present (the NAR fallback, not the corrupt
       ;; file-level bytes).
       (unless (string=? (pad "delta")
                         (call-with-input-file (string-append path "/a")
                           get-string-all))
         (error "v3 file a content wrong (corrupt bytes substituted?)")))
     (call-with-output-file (string-append root "/result-v3")
       (lambda (port)
         (format port "V3_OK=1~%"))))))
(close-connection store)
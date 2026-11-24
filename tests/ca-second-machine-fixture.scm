;;; goonix: CA-8 second-machine fixture.  Builds a small content-addressed
;;; graph from the bootstrap bash, plus a non-reproducible item, and writes
;;; their REALISED output names to a file.  Run once per independent store
;;; (same store prefix); two machines that build independently must arrive at
;;; the same realised names for the reproducible graph, and different names
;;; for the non-reproducible item.
(use-modules (guix) (guix tests) (guix store) (guix derivations)
             (gnu packages bootstrap) (ice-9 match))

(define store (open-connection))
(%graft? #f)

(define bash
  (add-to-store store "bash" #t "sha256"
                (search-bootstrap-binary "bash" (%current-system))))

;; A content-addressed derivation whose builder is SCRIPT (bash).  Returns the
;; REALISED output path (the content address), never a placeholder.
(define (ca-item name script)
  (let ((drv (derivation store name bash (list "-c" script)
                         #:sources (list bash)
                         #:addressing 'content)))
    (build-derivations store (list drv))
    (realised-output-path store drv "out")))

;; A reproducible leaf: fixed content.
(define leaf (ca-item "ca8-leaf" "printf 'leaf-payload' > \"$out\""))

;; A reproducible node that references the leaf by its realised path.  The
;; reference is the leaf's content address, identical on both machines.
(define node
  (ca-item "ca8-node"
           (format #f "printf 'node-payload %%s' '~a' > \"$out\"" leaf)))

;; A reproducible top that references the node.
(define top
  (ca-item "ca8-top"
           (format #f "printf 'top-payload %%s' '~a' > \"$out\"" node)))

;; A NON-reproducible item: it reads bytes from /dev/urandom (the build
;; environment exposes it) with bash's built-in read, so its content — and
;; thus its realised name — differs between two independent builds.  The test
;; cannot pass trivially: if the gate compared only derivation names this
;; would still match, but the realised names must differ.  The bootstrap bash
;; is 4.2: $RANDOM seeds from pid/time (coincided across the two namespaces)
;; and $SRANDOM (5.1+) does not exist, so urandom is the sound source.  read is
;; a builtin (no external binary in the build env); non-printable bytes
;; (including NUL) are stripped with a [:print:] pattern substitution.
(define nonce
  (ca-item "ca8-nonce"
           "IFS= read -r -N 32 raw < /dev/urandom; printf 'nonce-%s' \"${raw//[^[:print:]]/}\" > \"$out\""))

(define out (match (command-line) ((_ file) file)))
(call-with-output-file out
  (lambda (port)
    (write (list (list 'leaf (basename leaf))
                 (list 'node (basename node))
                 (list 'top (basename top))
                 (list 'nonce (basename nonce)))
           port)))
(close-connection store)
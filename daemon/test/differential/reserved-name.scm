;; Differential: a goonix reserved name (placeholder / self token) sent to a
;; SINGLE-path operation must be refused by both daemons (C++ readStorePath /
;; readStorePathStrict call assertNotReserved, store-api.cc:341/361 -> ca.cc:86).
;; A SET operation (readStorePaths) does NOT refuse reserved names in C++; the
;; Haskell daemon matches (readStorePathsSocket has no assertNotReserved).
;;
;; Known difference (recorded in STATUS.md): C++ checks the path while parsing
;; the operation input, before it may send stderr, so it rethrows and DROPS the
;; connection.  The Haskell daemon answers with a store error and KEEPS the
;; connection.  This test requires "refused" from both, not a connection drop.
;; It detects which behaviour occurred and checks the SET operation accordingly
;; (reconnecting if the daemon dropped the connection).
(use-modules (guix store) (guix ca) (srfi srfi-13) (srfi srfi-34)
             (ice-9 textual-ports))

(define (assert condition message)
  (unless condition (error message)))

(define socket (getenv "GUIX_DAEMON_SOCKET"))
(define store (open-connection socket))
(set-build-options store #:use-substitutes? #f)

;; A self-token path for output "out": <store>/<reserved-hash>-reserved-probe.
(define token (token-path "out" "reserved-probe"))
(assert (token-store-path? token) "constructed path is not a self token")

;; SINGLE-path operation: references (query-references, op 5) must refuse the
;; reserved name.
(define single-result
  (guard (c ((store-protocol-error? c)
             (store-protocol-error-message c)))
    (references store token)
    'accepted))
(assert (and (string? single-result)
             (string-contains single-result "refusing unresolved goonix token or placeholder"))
        (string-append "single-path op did not refuse the reserved name: "
                       (format #f "~s" single-result)))

;; Did the connection survive?  C++ drops it (EOF on the next read); Haskell
;; keeps it (a clean store error).  Probe with query-path-info on a NON-reserved
;; path: a clean store error means the connection is alive; EOF means it dropped.
(define probe-path (string-append (%store-prefix) "/00000000000000000000000000000000-connection-probe"))
(define connection-alive?
  (guard (c ((store-protocol-error? c) #t)
            (else #f))
    (query-path-info store probe-path)
    #t))

;; SET operation: query-substitutable-paths takes a path SET; C++ readStorePaths
;; does not assertNotReserved, so the reserved name is not refused at the read.
;; Reconnect if the daemon dropped the connection (C++ behaviour).
(define store2 (if connection-alive? store (open-connection socket)))
(unless connection-alive? (set-build-options store2 #:use-substitutes? #f))
(define set-result
  (guard (c ((store-protocol-error? c)
             (string-append "error:" (store-protocol-error-message c))))
    (substitutable-paths store2 (list token))))
(assert (list? set-result)
        (string-append "set operation unexpectedly refused the reserved name: "
                       (format #f "~s" set-result)))

(close-connection store2)
(unless connection-alive? (close-connection store))
(display (string-append "reserved-name single refused; set accepted; connection "
                        (if connection-alive? "kept (Haskell)" "dropped (C++)")
                        ": PASS\n"))
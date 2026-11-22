;;; goonix: substitute-log-drain regression client.  The daemon is started with
;;; GUIX pointing at a fake helper that floods stderr (>64 KiB) before replying
;;; on fd 4.  A correct daemon drains the log pipe while waiting for the reply
;;; (C++ getLineFromSubstituter selects on both descriptors) and answers this
;;; query promptly.  A daemon that reads only the reply pipe deadlocks and this
;;; client never returns (the runner's timeout catches it).
(use-modules (guix store) (guix derivations) (ice-9 textual-ports))

(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options store #:use-substitutes? #t #:offload? #f
                   #:substitute-urls '("file:///nonexistent-substitute-url"))

;; A derivation whose output is not in the store, so the daemon must ask the
;; substituter.  The builder never runs: this is a query, not a build.
(define drv
  (derivation store "substitute-log-flood" "/does-not-exist" '()))
(define out (derivation->output-path drv))

;; has-substitutes? (op 3) spawns `guix substitute --query' and reads the reply.
;; The fake helper floods the log pipe first; the daemon must drain it.
(define answer (has-substitutes? store out))
(format #t "substitute-log-flood query answered: ~a~%" answer)

;; Also exercise the info path (op 30), which reads several reply lines.
(define infos (substitutable-path-info store (list out)))
(format #t "substitute-log-flood info answered: ~a record(s)~%" (length infos))

(close-connection store)
(display "substitute-log-drain: PASS\n")
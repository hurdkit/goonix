;; goonix: focused HS-3 archive checks, independent of store deletion.
(use-modules (guix store)
             (guix tests)
             (guix build utils)
             ((guix serialization) #:hide (store-path read-string))
             ((gcrypt hash) #:prefix gcrypt:)
             (srfi srfi-34)
             (srfi srfi-64)
             (rnrs io ports)
             (rnrs bytevectors)
             (ice-9 textual-ports))

(test-begin "hs3-archive")
(test-runner-current (test-runner-simple))

(define root (getenv "HS3_ROOT"))
(define source (open-connection))
(define file (add-text-to-store source "signed.txt" "signed payload\n" '()))
(define dump
  (call-with-bytevector-output-port
   (lambda (port) (export-paths source (list file) port #:sign? #t))))
(close-connection source)

(define (with-fresh-store procedure)
  (let* ((name (format #f "~a/~a" root (random-text)))
         (store (string-append name "/store")))
    (mkdir name)
    (mkdir store)
    (dynamic-wind
      (lambda ()
        (setenv "NIX_STORE_DIR" store)
        (setenv "GUIX_DATABASE_DIRECTORY" (string-append name "/db"))
        (setenv "GUIX_STATE_DIRECTORY" (string-append name "/var"))
        (setenv "GUIX_DAEMON_SOCKET" (string-append name "/socket")))
      (lambda () (open-connection))
      (lambda ()
        (setenv "NIX_STORE_DIR" (string-append root "/store"))
        (setenv "GUIX_DATABASE_DIRECTORY" (string-append root "/db"))
        (setenv "GUIX_STATE_DIRECTORY" (string-append root "/var"))
        (setenv "GUIX_DAEMON_SOCKET" (string-append root "/var/socket"))))))

;; Test each archive against a different fresh store.  %store-prefix is
;; initialized when a connection opens, so the archive path is valid there.
(test-assert "signed archive restores into fresh store"
  (let* ((connection (with-fresh-store #f))
         (content "content addressed payload")
         (destination (store-path "text" (gcrypt:sha256 (string->utf8 content))
                                  "restored"))
         (archive
          (call-with-bytevector-output-port
           (lambda (port)
             (write-int 1 port)
             (write-file-tree #t port
                              #:file-type+size
                              (lambda (_) (values 'regular (string-length content)))
                              #:file-port (lambda (_) (open-input-string content)))
             (write-int #x4558494e port)
             (write-string destination port)
             (write-string-list '() port)
             (write-string "" port)
             (write-int 0 port)
             (write-int 0 port)))))
    (and (equal? (import-paths connection (open-bytevector-input-port archive))
                 (list destination))
         (valid-path? connection destination)
         (string=? (call-with-input-file destination get-string-all) content))))

(define (bytevector-prefix bytes length)
  (let ((result (make-bytevector length)))
    (bytevector-copy! bytes 0 result 0 length)
    result))

(test-assert "truncated archive is rejected"
  (let ((connection (with-fresh-store #f)))
    (guard (condition ((store-protocol-error? condition) #t))
      (import-paths connection
                    (open-bytevector-input-port
                     (bytevector-prefix dump (- (bytevector-length dump) 40))))
      #f)))

(test-assert "invalid store path is rejected before authentication"
  (let* ((connection (with-fresh-store #f))
         (text (add-text-to-store connection "x" "x" '()))
         (invalid (string-append (%store-prefix) "/../../notinstore"))
         (payload (string->utf8 "payload"))
         (archive
          (call-with-bytevector-output-port
           (lambda (port)
             (write-int 1 port)
             (write-file-tree #t port
                              #:file-type+size (lambda (_) (values 'regular (bytevector-length payload)))
                              #:file-port (lambda (_) (open-bytevector-input-port payload)))
             (write-int #x4558494e port)
             (write-string invalid port)
             (write-string-list '() port)
             (write-string "" port)
             (write-int 0 port)
             (write-int 0 port)))))
    (guard (condition ((store-protocol-error? condition) #t))
      (import-paths connection (open-bytevector-input-port archive))
      #f)))

(test-end)
(exit (if (zero? (test-runner-fail-count (test-runner-current))) 0 1))

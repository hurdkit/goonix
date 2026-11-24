;;; goonix: CA-7 corrupt-cache proxy.  Forwards to the real publisher, but
;;; serves WRONG bytes for one /goonix/file request (V3's file "a"), so the
;;; file-level NAR hash differs while the NAR itself stays correct.  Used by
;;; the gate's corrupt-cache fallback test.
(use-modules (web server) (web request) (web response) (web uri)
             ((guix http-client)
              #:select (http-fetch http-get-error? http-get-error-code
                        http-get-error-reason))
             (ice-9 match) (rnrs bytevectors) (rnrs io ports)
             (srfi srfi-11) (srfi srfi-34))

(define backend (match (command-line) ((_ url) url)))

;; The request to corrupt: V3's file "a" (the item name contains "ca-files-v3"
;; and the last path component is "a").
(define (corrupt? path)
  (and (string-prefix? "/goonix/file/" path)
       (string-contains path "ca-files-v3")
       (string-suffix? "/a" path)))

(define (handler request body)
  (let* ((path (uri-path (request-uri request)))
         (target (string->uri (string-append backend path))))
    (if (corrupt? path)
        ;; Serve wrong bytes for this file only.
        (values '((content-type . (application/octet-stream)))
                (string->utf8 "CORRUPT-BYTES"))
        ;; Forward everything else (narinfo, NAR, file list, other files),
        ;; keeping the backend's status code; the web server reframes the body.
        (guard (c ((http-get-error? c)
                   (values (build-response #:code (http-get-error-code c))
                           (string->utf8 (http-get-error-reason c)))))
          ;; guix http-fetch returns (values PORT RESPONSE), port first.
          (let-values (((port resp) (http-fetch target #:text? #f)))
            (let ((data (get-bytevector-all port)))
              (close-port port)
              (values (build-response
                       #:code (response-code resp)
                       #:headers `((content-type
                                    . ,(or (assq-ref (response-headers resp)
                                                     'content-type)
                                           '(application/octet-stream)))))
                      data)))))))

;; Guile's http-open wants the address as an integer (inet-pton), not a string.
(run-server handler 'http
            `(#:port 6793 #:addr ,(inet-pton AF_INET "127.0.0.1")))
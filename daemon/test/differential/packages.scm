;; HS-6 T3: prepare inputs or compile/check real gnu-build-system packages.
(use-modules (guix) (guix store) (guix packages) (guix derivations)
             (gnu packages base) (gnu packages compression)
             (srfi srfi-1) (srfi srfi-26) (ice-9 textual-ports))
(%graft? #f)
(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(define prepare? (equal? (getenv "HS6_MODE") "prepare"))
(define packages (list hello bzip2 sed))
(define input-paths
  (let ((port (open-input-file (getenv "HS6_INPUT_PATHS"))))
    (let loop ((result '()))
      (let ((line (get-line port)))
        (if (eof-object? line)
            (begin (close-port port) (delete-duplicates (reverse result) string=?))
            (loop (cons line result)))))))
(define (configure-builds)
  (set-build-options store
                     #:use-substitutes? prepare?
                     #:substitute-urls (if prepare?
                                         '("https://bordeaux.guix.gnu.org"
                                           "https://ci.guix.gnu.org")
                                         '())
                     #:offload? #f
                     #:max-build-jobs 1))
(define derivations (map (lambda (package) (package-derivation store package)) packages))
(define outputs (map derivation->output-path derivations))
(configure-builds)
(define (path-references path)
  (let ((info (run-with-store store (query-path-info* path))))
    (if info (path-info-references info) '())))
(define (include-references paths)
  (delete-duplicates
   (append paths (append-map path-references paths))
   string=?))
(define (prepare-closure paths)
  (let ((closure (include-references paths)))
    (unless (every (cut valid-path? store <>) closure)
      (format #t "preparing-reference-closure=~a~%" (length closure))
      (configure-builds)
      (unless (build-things store closure)
        (error "reference-closure preparation failed")))
    (let ((expanded (include-references closure)))
      (if (= (length expanded) (length closure))
          (format #t "prepared-closure=~a~%" (length closure))
          (prepare-closure expanded)))))
(define (derivation-output-paths derivation)
  (map (lambda (entry)
         (derivation-output-path (cdr entry)))
       (derivation-outputs derivation)))
(define direct-input-paths
  (delete-duplicates
   (append input-paths
           (append-map (lambda (drv)
                         (append-map (lambda (input)
                                       (map (lambda (name)
                                              (derivation->output-path
                                               (derivation-input-derivation input) name))
                                            (derivation-input-sub-derivations input)))
                                     (derivation-inputs drv)))
                       derivations))
   string=?))
(when prepare?
  (format #t "preparing-inputs=~a~%" (length direct-input-paths))
  (configure-builds)
  (unless (build-things store direct-input-paths)
    (error "input preparation failed"))
  (prepare-closure direct-input-paths))
(for-each
 (lambda (package drv output)
   (when prepare?
     (when (or (valid-path? store output) (file-exists? output))
       (error "preparation substituted a selected package output" output)))
   (unless prepare?
     (when (valid-path? store output)
       (error "selected output was already present before differential build" output))
     (format #t "building=~a~%" (derivation-file-name drv))
     (configure-builds)
     (unless (build-derivations store (list drv))
       (error "package build failed" (derivation-file-name drv)))
     (unless (valid-path? store output)
       (error "package output is not registered" output)))
   (format #t "package=~a version=~a output=~a~a~%"
           (package-name package) (package-version package) output
           (if prepare? ""
               (string-append " hash="
                (bytevector->nix-base32-string (query-path-hash store output))
                " size=" (number->string (path-info-nar-size (query-path-info store output)))))))
 packages derivations outputs)
(close-connection store)
(format #t "HS-6 package ~a: PASS~%" (if prepare? "input preparation" "differential build"))

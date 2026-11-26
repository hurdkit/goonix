;;; goonix: CA-6 step 4 boot gate — the small system lowered under the 'adopted
;;; POLICY as a user would select it, booted in a marionette VM.  Run inside
;;; the private namespace (the implementation daemon, /gnu/store bound
;;; writable, bordeaux substitutes).  NO pre-built closure and NO direct
;;; adopt-derivation call: package lowering goes through lower-bag-with-
;;; addressing -> adopt-lowered-derivation, which adopts upstream packages and
;;; re-lowers glibc and flagged items content-addressed from source.
(use-modules (gnu)
             (gnu tests)
             (gnu system image)
             (gnu image)
             (guix ca policy)
             (guix store)
             (guix monads)
             (guix gexp)
             (guix derivations)
             (guix packages)
             (gnu build marionette)
             (gnu packages virtualization)
             (ice-9 match)
             (srfi srfi-64))

(define store (open-connection))

;; The small system: the simple OS (base services), marionetteed so the host
;; can confirm it booted.
(define os
  (marionette-operating-system (simple-operating-system)))

;; Lower the VM image under the 'adopted policy.  Upstream packages are
;; adopted (their binaries rewritten to content-addressed items); glibc and
;; flagged items are re-lowered content-addressed from source.
(define image-drv
  (parameterize ((%package-addressing-policy 'adopted))
    (run-with-store store
      (lower-object (system-image (os->image os #:type qcow2-image-type))))))
(format #t "adopted-policy image derivation: ~a~%"
        (derivation-file-name image-drv))
(build-derivations store (list image-drv))
;; A content-addressed image's derivation names only a token; the daemon
;; holds the path it realised.  An input-addressed one is unchanged.
(define image-path (realised-output-path store image-drv "out"))
(format #t "adopted-policy VM image realised: ~a~%" image-path)

;; Record what the policy did to the closure: an adopted item's deriver is a
;; graft derivation that imports (guix ca build graft) (the two-pass
;; content-addressed graft); an item built from source has a content/resolved
;; addressing marker but no such graft; the rest stayed input-addressed.
(define (classify closure)
  (let ((adopted '()) (from-source '()) (input-addressed '()) (unknown '()))
    (for-each
     (lambda (item)
       (let* ((info (query-path-info store item))
              (drv-file (and info (path-info-deriver info)))
              (text (and drv-file (file-exists? drv-file)
                         (call-with-input-file drv-file get-string-all)))
              (name (store-path-package-name item)))
         (cond
          ((not text) (set! unknown (cons name unknown)))
          ((string-contains text "guix ca build graft")
           (set! adopted (cons name adopted)))
          ((or (string-contains text "goonixAddressing\",\"content")
               (string-contains text "goonixAddressing\",\"resolved"))
           (set! from-source (cons name from-source)))
          (else (set! input-addressed (cons name input-addressed))))))
     closure)
    (format #t "CLOSURE: ~a items~%" (length closure))
    (for-each
     (match-lambda
       ((label . names)
        (format #t "~a: ~a~%" label (length names))
        (for-each (lambda (n) (format #t "  ~a ~a~%" label n))
                  (sort names string<?))))
     `(("ADOPTED" . ,adopted)
       ("BUILT-FROM-SOURCE" . ,from-source)
       ("INPUT-ADDRESSED" . ,input-addressed)
       ("NO-DERIVER" . ,unknown)))))
(classify (requisites store (list image-path)))

;; QEMU to boot it (KVM is available in the namespace).
(define qemu-drv (package-derivation store qemu-minimal))
(build-derivations store (list qemu-drv))
(define qemu-bin (string-append (realised-output-path store qemu-drv "out")
                                "/bin/qemu-system-x86_64"))

(define command
  (list qemu-bin
        "-enable-kvm" "-m" "1024" "-snapshot"
        "-drive" (format #f "file=~a,if=virtio" image-path)
        "-nic" "user,model=virtio-net-pci"
        "-no-reboot"))

(define marionette (make-marionette command #:timeout 180))

(test-begin "ca6-adopted-policy-boot")
(test-assert "the adopted-policy system boots (uname)"
  (match (marionette-eval '(uname) marionette)
    (#("Linux" host-name version _ architecture)
     (format #t "booted: ~a ~a ~a~%" host-name version architecture)
     (string=? host-name (operating-system-host-name os)))
    (_ #f)))
(test-end "ca6-adopted-policy-boot")

(close-connection store)
;;; goonix: the system secrets service.
;;;
;;; A new file of ours; gnu/services is not edited (00-overview.md, section
;;; 6).  At activation and at boot, before any service that requires
;;; 'secrets', it decrypts each declared secret with the machine's identity
;;; into /run/secrets (a tmpfs), with the owner, group and mode vault.scm
;;; gives, as a new directory that replaces the old one in one step.  What is
;;; no longer declared is gone.  Plaintext never enters the store: the
;;; closure carries the ciphertext and the public vault data only.
;;;
;;; The first identity of a new machine reaches it outside the store: either
;;; the machine makes one at first boot and shows the public key (which
;;; becomes a recipient through rekey and reconfigure), or the host sends one
;;; through the first-boot copy service Guix already has for virtual machines
;;; (gnu build secret-service).  Both leave the identity at
;;; /etc/guix/secrets/identity.txt, mode 600.
(define-module (gnu services goonix-secrets)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services configuration)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (guix self)
  #:use-module (guix secrets vault)
  #:use-module (guix secrets materialise)
  #:use-module ((guix build utils) #:select (mkdir-p))
  #:use-module ((gnu build secret-service) #:select (secret-service-send-secrets))
  #:use-module ((gnu packages gnupg) #:select (guile-gcrypt))
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (secrets-configuration
            secrets-configuration?
            secrets-configuration-vault
            secrets-configuration-identity
            secrets-configuration-first-boot-identity?
            secrets-configuration-first-boot-copy?
            secrets-configuration-directory
            secrets-service-type
            %secrets-directory
            secrets-first-boot-copy))

(define %secrets-directory "/run/secrets")

(define not-config?
  ;; Select (guix …) and (gnu …) modules, except (guix config).
  (match-lambda
    (('guix 'config) #f)
    (('guix rest ...) #t)
    (('gnu rest ...) #t)
    (_ #f)))

(define (empty-vault-directory)
  "A vault directory with an empty vault.scm, the default before a project
supplies its own.  It declares no secrets, so it materialises nothing."
  (file-union "secrets-vault"
              `(("vault.scm"
                 ,(plain-file "vault.scm"
                              "(vault (format 1) (recipients) (secrets))\n")))))

(define-configuration secrets-configuration
  (vault
   (file-like (empty-vault-directory))
   "The vault directory: vault.scm and one armored age file per secret, as
tracked files of the project.  The ciphertext is in the store; the plaintext
is not."
   empty-serializer)
  (identity
   (string "/etc/guix/secrets/identity.txt")
   "The machine's identity file, outside the store.  An SSH host key may be
named instead.  It is never copied into a store item."
   empty-serializer)
  (first-boot-identity?
   (boolean #f)
   "When true and the identity file is missing at first boot, make one and
show its public key on the console, so that it can become a recipient.  The
private half stays on the machine, mode 600."
   empty-serializer)
  (first-boot-copy?
   (boolean #f)
   "When true, the identity is sent by the host through the first-boot copy
service (gnu build secret-service) rather than made on the machine.  The
activation then skips materialisation while the identity is absent, and the
secrets service waits for the copy before materialising, so a service that
requires 'secrets' sees the files."
   empty-serializer)
  (directory
   (string %secrets-directory)
   "The public path of the materialised secrets, a symlink to the current
generation in the volatile directory (the public path with '.d' appended)."
   empty-serializer))

(define (secrets-generation-directory config)
  "The volatile directory that holds the generations, the public path with
'.d' appended (/run/secrets.d for the default /run/secrets).  The shepherd
one-shot 'secrets' mounts it as a tmpfs at run time (ensure-volatile-directory),
deciding the platform then: a tmpfs translator on the Hurd, mount(2) on Linux.
It is not a file-system-service-type entry, which on the Hurd would become a
mount(2) call with no Hurd path and stop the boot."
  (string-append (secrets-configuration-directory config) ".d"))

(define (secrets-activation config)
  "Return the activation gexp that materialises the declared secrets."
  (let ((vault (secrets-configuration-vault config))
        (identity (secrets-configuration-identity config))
        (directory (secrets-configuration-directory config))
        (first-boot? (secrets-configuration-first-boot-identity? config))
        (copy? (secrets-configuration-first-boot-copy? config)))
    (with-extensions (list guile-gcrypt)
      (with-imported-modules `(((guix config) => ,(make-config.scm))
                               ,@(source-module-closure
                                  '((guix secrets materialise)
                                    (guix secrets vault)
                                    (guix secrets age)
                                    (guix build utils))
                                  #:select? not-config?))
        #~(begin
            (use-modules (guix secrets materialise)
                         (guix secrets vault)
                         (guix build utils)
                         (ice-9 textual-ports))
            (let* ((identity-file #$identity)
                   (public
                    (if #$first-boot?
                        (ensure-machine-identity identity-file)
                        (and (file-exists? identity-file)
                             (identity-public-text
                              (read-identity identity-file))))))
              (when (and #$first-boot? public)
                ;; Show the public half so it can become a recipient; the
                ;; private half never leaves the machine.
                (format (current-error-port)
                        "goonix secrets: machine identity public key: ~a~%"
                        public))
              (cond
               ((not (file-exists? identity-file))
                ;; With a first-boot copy the identity has not arrived yet at
                ;; activation; the secrets service materialises after it.
                (if #$copy?
                    (format (current-error-port)
                            "goonix secrets: waiting for the first-boot identity copy~%")
                    (error "no machine identity; set first-boot-identity? or send one through the first-boot copy"
                           identity-file)))
               (else
                (let ((generations #$(secrets-generation-directory config)))
                  (if (volatile-generation-directory? generations)
                      (let* ((identity (read-identity identity-file))
                             (vault (call-with-input-file
                                        (string-append #$vault "/vault.scm")
                                      read-vault))
                             (generation (next-generation generations))
                             (fresh (string-append generations "/"
                                                   (number->string generation))))
                        (materialise-secrets #$vault vault identity fresh)
                        (publish-generation generations generation
                                            #$directory))
                      ;; The tmpfs is not mounted yet: activation runs before
                      ;; shepherd mounts the non-boot file systems, and on
                      ;; Guix System /run is on the root disk, so writing a
                      ;; generation now would put plaintext on the disk (D9).
                      ;; Defer to the shepherd one-shot 'secrets', which
                      ;; requires file-systems and does this after the mount.
                      ;; Nothing is created here.
                      (format (current-error-port)
                              "goonix secrets: ~a not mounted yet; deferring to the secrets service~%"
                              generations)))))))))))

(define (secrets-shepherd-service config)
  "A one-shot service that materialises the secrets at boot, before any
service that requires 'secrets'.  Activation already materialises them on
reconfigure; this repeats it at boot, when /run/secrets.d is an empty tmpfs
again and the first activation makes generation 1.  With a first-boot copy it
waits for the identity to arrive."
  (list (shepherd-service
         (documentation "Materialise the declared secrets into /run/secrets.")
         (provision '(secrets))
         (requirement (if (secrets-configuration-first-boot-copy? config)
                          '(file-systems secret-service-client)
                          '(file-systems)))
         (one-shot? #t)
         (modules `((guix secrets materialise)
                    (guix secrets vault)
                    (guix build utils)
                    (ice-9 textual-ports)))
         (start
          (with-extensions (list guile-gcrypt)
            (with-imported-modules `(((guix config) => ,(make-config.scm))
                                     ,@(source-module-closure
                                        '((guix secrets materialise)
                                          (guix secrets vault)
                                          (guix secrets age)
                                          (guix build utils))
                                        #:select? not-config?))
              #~(lambda ()
                  (use-modules (guix secrets materialise)
                               (guix secrets vault)
                               (guix build utils))
                  (let* ((identity-file #$(secrets-configuration-identity config))
                         (directory #$(secrets-configuration-directory config))
                         (generations #$(secrets-generation-directory config)))
                    ;; Mount the volatile directory now, after file-systems,
                    ;; deciding the platform at run time (tmpfs translator on
                    ;; the Hurd, mount(2) on Linux).  This raises if it cannot
                    ;; be made volatile; never materialise into a non-volatile
                    ;; directory.
                    (ensure-volatile-directory generations)
                    (if (file-exists? identity-file)
                        (let* ((identity (read-identity identity-file))
                               (vault (call-with-input-file
                                          (string-append
                                           #$(secrets-configuration-vault config)
                                           "/vault.scm")
                                        read-vault))
                               (generation (next-generation generations))
                               (fresh (string-append generations "/"
                                                     (number->string generation))))
                          (materialise-secrets
                           #$(secrets-configuration-vault config)
                           vault identity fresh)
                          (publish-generation generations generation directory)
                          #t)
                        (begin
                          (format (current-error-port)
                                  "goonix secrets: no identity at ~a~%"
                                  identity-file)
                          #f)))))))
         (stop #~(const #f)))))

(define secrets-service-type
  (service-type
   (name 'secrets)
   (extensions
    (list (service-extension activation-service-type
                             secrets-activation)
          (service-extension shepherd-root-service-type
                             secrets-shepherd-service)))
   (default-value (secrets-configuration))
   (description
    "Decrypt the project's declared secrets with the machine's identity into
a volatile directory at activation and boot, with their declared owner,
group and mode.  Plaintext never enters the store.")))

(define* (secrets-first-boot-copy address secret-root
                                  #:key (identity-file #f))
  "Send a machine's first identity to a guest through the first-boot copy
service Guix already has for virtual machines (gnu build secret-service).
SECRET-ROOT is a directory on the host holding etc/guix/secrets/identity.txt
(the private half, mode 600) and any other first-boot material; it is sent to
the guest listening at ADDRESS, a socket address.  When IDENTITY-FILE is given
and the identity is missing under SECRET-ROOT, one is made there first and its
public key returned, so the host can make it a recipient (rekey, then
reconfigure).  The private half never enters the store.  Returns the public
key text when an identity was made, else #t on a successful send, #f on
failure."
  (let* ((identity-target (string-append secret-root
                                         "/etc/guix/secrets/identity.txt"))
         (made-public
          (and identity-file
               (not (file-exists? identity-target))
               (begin
                 (mkdir-p (dirname identity-target))
                 (let ((public (ensure-machine-identity identity-target)))
                   public)))))
    (let ((sent (secret-service-send-secrets address secret-root)))
      (cond (made-public made-public)
            (sent #t)
            (else #f)))))
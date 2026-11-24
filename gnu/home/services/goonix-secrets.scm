;;; goonix: the home secrets service.
;;;
;;; A new file of ours; gnu/home/services is not edited (00-overview.md,
;;; section 6).  The home counterpart of secrets-service-type: at activation
;;; it decrypts each declared secret with the user's identity into a volatile
;;; directory under XDG_RUNTIME_DIR, with the owner, group and mode vault.scm
;;; gives, as a new directory that replaces the old one in one step.  What is
;;; no longer declared is gone.  Plaintext never enters the store.
;;;
;;; A home has no tmpfs of its own; XDG_RUNTIME_DIR is the user's volatile
;;; runtime directory (a tmpfs on a logind system).  The materialisation falls
;;; back to a private directory there, and warns when it is not volatile, just
;;; as the vault's exec command does.
(define-module (gnu home services goonix-secrets)
  #:use-module (gnu home services)
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (guix self)
  #:use-module (guix secrets vault)
  #:use-module ((gnu packages gnupg) #:select (guile-gcrypt))
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (home-secrets-configuration
            home-secrets-configuration?
            home-secrets-configuration-vault
            home-secrets-configuration-identity
            home-secrets-configuration-directory
            home-secrets-service-type))

(define not-config?
  (match-lambda
    (('guix 'config) #f)
    (('guix rest ...) #t)
    (('gnu rest ...) #t)
    (_ #f)))

(define (empty-vault-directory)
  "A vault directory with an empty vault.scm, the default before a project
supplies its own.  It declares no secrets, so it materialises nothing."
  (file-union "home-secrets-vault"
              `(("vault.scm"
                 ,(plain-file "vault.scm"
                              "(vault (format 1) (recipients) (secrets))\n")))))

(define-configuration home-secrets-configuration
  (vault
   (file-like (empty-vault-directory))
   "The vault directory: vault.scm and one armored age file per secret, as
tracked files of the project.  The ciphertext is in the store; the plaintext
is not."
   empty-serializer)
  (identity
   (string "")
   "The user's identity file, outside the store.  Empty means the default
~/.config/guix/secrets/identity.txt.  An SSH key may be named instead.  It is
never copied into a store item."
   empty-serializer)
  (directory
   (string "guix-secrets")
   "Where the secrets are materialised, relative to XDG_RUNTIME_DIR (the
user's volatile runtime directory)."
   empty-serializer))

(define (home-secrets-activation config)
  "Return the activation gexp that materialises the declared secrets into the
user's volatile runtime directory."
  (let ((vault (home-secrets-configuration-vault config))
        (identity (home-secrets-configuration-identity config))
        (directory (home-secrets-configuration-directory config)))
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
            (let* ((identity-file
                    (if (string-null? #$identity)
                        (string-append (getenv "HOME")
                                       "/.config/guix/secrets/identity.txt")
                        #$identity))
                   (runtime (or (getenv "XDG_RUNTIME_DIR")
                                (string-append "/run/user/"
                                               (number->string (getuid)))))
                   (target (string-append runtime "/" #$directory))
                   (generations (string-append target ".d")))
              (unless (file-exists? identity-file)
                (error "no home identity; create one with guix secrets init"
                       identity-file))
              (let* ((identity (read-identity identity-file))
                     (vault (call-with-input-file
                                (string-append #$vault "/vault.scm")
                              read-vault))
                     (generation (next-generation generations))
                     (fresh (string-append generations "/"
                                           (number->string generation))))
                (mkdir-p generations)
                (materialise-secrets #$vault vault identity fresh)
                (publish-generation generations generation target))))))))

(define home-secrets-service-type
  (service-type
   (name 'home-secrets)
   (extensions
    (list (service-extension home-activation-service-type
                             home-secrets-activation)))
   (default-value (home-secrets-configuration))
   (description
    "Decrypt the project's declared secrets with the user's identity into a
volatile directory under XDG_RUNTIME_DIR at activation, with their declared
owner, group and mode.  Plaintext never enters the store.")))
;;; goonix: materialise a vault's secrets on a machine.
;;;
;;; This is the machine side of the vault: it decrypts the declared secrets
;;; with the machine's identity into a volatile directory (/run/secrets on a
;;; system), with the owner, group and mode vault.scm gives.  Plaintext never
;;; enters the store; the ciphertext is what the system closure carries.
;;;
;;; The core procedure works on any directory so that it can be tested without
;;; root and without a real /run.  The service wraps it with a tmpfs mounted at
;;; a separate directory (/run/secrets.d): each activation decrypts into a new
;;; generation directory inside it, and the public path (/run/secrets) is a
;;; symlink swapped in one step.  This is how agenix and sops-nix do it (D9).
(define-module (guix secrets materialise)
  #:use-module (guix secrets age)
  #:use-module (guix secrets vault)
  #:use-module ((guix build utils) #:select (mkdir-p delete-file-recursively))
  #:use-module ((guix build syscalls)
                #:select (mount setxattr MS_NODEV MS_NOSUID MS_NOEXEC))
  #:use-module (ice-9 match)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 binary-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (materialise-secrets
            materialise-secret
            next-generation
            publish-generation
            volatile-generation-directory?
            ensure-volatile-directory
            machine-identity-file
            ensure-machine-identity
            identity-public-text))

(define (machine-identity-file)
  "The default identity of a machine: /etc/guix/secrets/identity.txt, or the
file named by GUIX_SECRETS_IDENTITY.  An SSH host key may be named instead."
  (or (getenv "GUIX_SECRETS_IDENTITY")
      "/etc/guix/secrets/identity.txt"))

(define (ensure-machine-identity file)
  "Make a machine identity at FILE when there is none, and return its public
key text.  The private half is written mode 600 and never enters the store.
The public half is shown so that it can become a recipient (rekey, then
reconfigure).  An existing identity is kept and its public half returned."
  (cond
   ((file-exists? file)
    (let ((identity (read-identity file)))
      (identity-public-text identity)))
   (else
    (let ((identity (generate-x25519-identity)))
      (mkdir-p (dirname file))
      (call-with-output-file file
        (lambda (port)
          (chmod file #o600)
          (display (string-append "# goonix machine age identity\n"
                                  identity "\n")
                   port)))
      (x25519-identity-public identity)))))

(define (identity-public-text identity)
  "The public recipient text of an identity material: an age X25519 string,
an SSH public key, or a parsed SSH identity."
  (match identity
    ((? string? text) (x25519-identity-public text))
    (('ssh public-blob public x25519) (ssh-public-key-text public))
    (_ (error "unsupported identity material" identity))))

(define (materialise-secret secret vault-directory identity target)
  "Decrypt one declared SECRET into TARGET/NAME with its owner, group and
mode.  The plaintext is written to a temporary file in TARGET and renamed,
so a reader never sees a half-written secret.  Returns the file name."
  (let* ((name (symbol->string (secret-name secret)))
         (file (string-append target "/" name))
         (temporary (string-append target "/." name ".tmp"))
         (plaintext (decrypt-age-file
                     (call-with-input-file
                         (string-append vault-directory "/" name ".age")
                       get-string-all)
                     (list identity))))
    (call-with-output-file temporary
      (lambda (port)
        (chmod temporary (secret-mode secret))
        (put-bytevector port plaintext)))
    (let ((owner (secret-owner secret))
          (group (secret-group secret)))
      (when owner
        (let ((entry (false-if-exception (getpwnam owner))))
          (if entry
              (chown temporary (passwd:uid entry)
                     (if group
                         (let ((g (false-if-exception (getgrnam group))))
                           (if g (group:gid g) (passwd:gid entry)))
                         (passwd:gid entry)))
              (error "unknown secret owner" owner))))
      (when (and group (not owner))
        (let ((g (false-if-exception (getgrnam group))))
          (if g
              (chown temporary -1 (group:gid g))
              (error "unknown secret group" group)))))
    (rename-file temporary file)
    file))

(define (materialise-secrets vault-directory vault identity target)
  "Decrypt every declared secret of VAULT into TARGET, a fresh generation
directory.  Only the declared secrets are present; what is no longer declared
is gone.  TARGET is created mode 751: others may traverse it to reach a secret
declared for them, but not list it; each file's own owner and mode protect it
(agenix uses 751 for the same reason).  Returns the list of file names written."
  (mkdir-p target)
  (chmod target #o751)
  (map (lambda (secret)
         (materialise-secret secret vault-directory identity target))
       (vault-secrets vault)))

(define (next-generation directory)
  "Return one higher than the highest generation number in DIRECTORY, a
directory of generation subdirectories named by number.  An empty or absent
directory gives 1, so the first activation after a reboot makes generation 1."
  (let ((entries (or (false-if-exception (scandir directory)) '())))
    (+ 1 (fold (lambda (name highest)
                 (let ((n (string->number name)))
                   (if (and n (exact-integer? n) (positive? n) (> n highest))
                       n
                       highest)))
               0
               entries))))

(define (publish-generation directory generation live)
  "Make LIVE, the public path, point at DIRECTORY/GENERATION in one step, then
remove the older generations.  LIVE is a symlink: a pivot symlink is created
next to it and renamed onto it, and rename(2) of a symlink onto a symlink is
atomic, so a reader always resolves LIVE to a complete generation, never a
partial set and never a missing path.  The symlink holds no plaintext, so it
does not matter that its parent (/run) is not a tmpfs.  GENERATION is an
integer; the generation directories live in DIRECTORY, the volatile tmpfs."
  (let* ((target (string-append directory "/" (number->string generation)))
         (pivot (string-append live ".tmp")))
    ;; A pivot left by an interrupted earlier swap is removed first.
    (when (or (file-exists? pivot)
              (false-if-exception (lstat pivot)))
      (delete-file pivot))
    (symlink target pivot)
    (rename-file pivot live)
    ;; Remove the older generations; the one just published is kept.
    (for-each (lambda (name)
                (let ((n (string->number name)))
                  (when (and n (exact-integer? n) (positive? n)
                             (< n generation))
                    (delete-file-recursively
                     (string-append directory "/" name)))))
              (or (false-if-exception (scandir directory)) '()))))

(define (volatile-generation-directory? directory)
  "Return #t when DIRECTORY is the mounted volatile file system the secrets
may be written to, #f when it is not yet mounted.  The check is that DIRECTORY
is a mount point: its stat:dev differs from that of its parent.  This is
portable (it needs only stat) and is what tells activation, which runs before
shepherd mounts the non-boot file systems, that the tmpfs is not there yet: on
Guix System /run is on the root disk, so writing a generation before the mount
would put plaintext on the disk (D9).  When DIRECTORY does not exist yet it is
certainly not mounted, so the answer is #f and nothing is created.  The caller
defers to the shepherd one-shot 'secrets', which requires file-systems and
runs after the mount; on reconfigure the tmpfs is already mounted, so this is
#t and activation materialises at once."
  (let ((st (stat directory #f)))
    (and st
         (eq? 'directory (stat:type st))
         (let ((parent (stat (dirname directory) #f)))
           (and parent
                (not (= (stat:dev st) (stat:dev parent))))))))

(define (ensure-volatile-directory directory)
  "Make DIRECTORY the volatile file system the secrets are materialised into,
mounting it if it is not already.  The platform is decided here, at run time,
not at evaluation time: a service's extensions never see the operating system,
and the Hurd's file-system-service-type would turn a tmpfs entry into a
mount(2) call with no Hurd path, stopping the boot.  So the service mounts its
own volatile directory and the guest decides how.

If DIRECTORY is already a mount point (volatile-generation-directory?), return.
Otherwise create it mode 751 and mount a tmpfs on it: on the Hurd
(utsname:sysname is \"GNU\") set a tmpfs translator on the node, the way
(gnu build hurd-boot) set-translator does — setxattr \"gnu.translator\" with the
command joined by NUL characters, as /dev/shm is set; on Linux, mount(2) a
tmpfs with nodev/nosuid/noexec.  Then check again: if DIRECTORY is still not a
mount point, raise.  Never materialise into a directory that is not volatile.
Only the shepherd one-shot 'secrets' calls this, after file-systems; activation
keeps its rule of materialising only when the directory is already volatile."
  (unless (volatile-generation-directory? directory)
    (mkdir-p directory)
    (chmod directory #o751)
    (if (string=? (utsname:sysname (uname)) "GNU")
        ;; GNU/Hurd: a tmpfs translator on the node, as /dev/shm is set in
        ;; (gnu build hurd-boot).  The translator record is an attribute of the
        ;; directory and holds no plaintext; /run is recreated each boot, so it
        ;; is set again each boot.
        (setxattr directory "gnu.translator"
                  (string-join '("/hurd/tmpfs" "--mode=751" "1M")
                               "\0" 'suffix))
        ;; Linux: mount a tmpfs.
        (mount "none" directory "tmpfs"
               (logior MS_NODEV MS_NOSUID MS_NOEXEC) "mode=751"))
    (unless (volatile-generation-directory? directory)
      (error "could not mount a volatile file system for the secrets"
             directory))))
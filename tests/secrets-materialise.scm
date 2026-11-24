;;; goonix: machine materialisation of a vault, independent of a service.
(use-modules (guix secrets age)
             (guix secrets vault)
             (guix secrets materialise)
             ((guix build utils) #:select (delete-file-recursively find-files
                                           symbolic-link? mkdir-p))
             (guix build syscalls)
             (rnrs bytevectors)
             (ice-9 textual-ports)
             (ice-9 binary-ports)
             (ice-9 ftw)
             (srfi srfi-1)
             (srfi srfi-64))

(define root (mkdtemp! "/tmp/goonix-materialise-unit.XXXXXX"))
(define vault-path (string-append root "/vault"))
(define live (string-append root "/run/secrets"))
(define canary "materialise-canary-7f3a9c")
(define id (generate-x25519-identity))
(define public (x25519-identity-public id))
;; The unit test runs unprivileged, so it materialises with the current
;; user and group (a process may chown to its own uid/gid).  The service
;; runs as root at activation and uses the declared root owner there.
(define me (passwd:name (getpwuid (getuid))))
(define my-group (group:name (getgrgid (getgid))))
(mkdir vault-path)
(call-with-output-file (string-append vault-path "/vault.scm")
  (lambda (port)
    (format port "(vault (format 1) (recipients (owner ~s))
 (secrets (token (for owner) (owner ~s) (group ~s) (mode #o400))
          (guest (kind ssh-key) (for owner) (owner ~s))))\n"
            public me my-group me)))
(define parsed (call-with-input-file (string-append vault-path "/vault.scm") read-vault))
(add-secret vault-path parsed 'token 'file (string->utf8 canary) id)
(generate-ssh-key vault-path parsed 'guest id)

(test-begin "secrets-materialise")
(test-runner-on-group-end!
 (test-runner-current)
 (lambda (runner) (delete-file-recursively root)))

(test-equal "materialise writes the declared plaintext" canary
  (begin
    (materialise-secrets vault-path parsed id live)
    (call-with-input-file (string-append live "/token") get-string-all)))

(test-equal "materialise sets the declared mode" #o400
  (logand (stat:mode (stat (string-append live "/token"))) #o777))

(test-equal "materialise sets the declared owner and group"
  (cons (getuid) (getgid))
  (let ((st (stat (string-append live "/token"))))
    (cons (stat:uid st) (stat:gid st))))

(test-equal "the target directory is traversable but not listable" #o751
  (logand (stat:mode (stat live)) #o777))

(test-equal "only the declared secrets are present" '("guest" "token")
  (sort (scandir live (lambda (f) (not (string-prefix? "." f)))) string<?))

(test-equal "the ssh-key secret is materialised too" #t
  (file-exists? (string-append live "/guest")))

(test-equal "a wrong identity is refused" #t
  (let ((other (generate-x25519-identity)))
    (catch #t
      (lambda ()
        (materialise-secrets vault-path parsed other
                             (string-append root "/wrong"))
        #f)
      (lambda (key . args) #t))))

(test-equal "publish-generation swaps the public symlink in one step" #t
  (let* ((generations (string-append root "/run/secrets.d"))
         (link (string-append root "/run/public"))
         (generation (next-generation generations))
         (fresh (string-append generations "/" (number->string generation))))
    (materialise-secrets vault-path parsed id fresh)
    (publish-generation generations generation link)
    ;; The public path is a symlink to the generation, and resolves to it.
    (and (symbolic-link? link)
         (string=? (readlink link) fresh)
         (string=? (call-with-input-file (string-append link "/token")
                     get-string-all)
                   canary))))

(test-equal "the public path always resolves across a second generation" #t
  (let* ((generations (string-append root "/run/secrets.d"))
         (link (string-append root "/run/public"))
         (first (readlink link))
         (generation (next-generation generations))
         (fresh (string-append generations "/" (number->string generation))))
    ;; A second generation is published; the public path keeps resolving, to
    ;; the new generation, and the older one is gone.
    (materialise-secrets vault-path parsed id fresh)
    (publish-generation generations generation link)
    (and (not (string=? (readlink link) first))
         (string=? (readlink link) fresh)
         (string=? (call-with-input-file (string-append link "/token")
                     get-string-all)
                   canary)
         (not (file-exists? first)))))

(test-equal "publish-generation removes what is no longer declared" '("token")
  (let* ((generations (string-append root "/run/secrets.d"))
         (link (string-append root "/run/public"))
         (generation (next-generation generations))
         (fresh (string-append generations "/" (number->string generation)))
         (smaller-vault
          (call-with-input-string
              (format #f "(vault (format 1) (recipients (owner ~s))
 (secrets (token (for owner) (owner ~s))))\n" public me)
            read-vault)))
    (materialise-secrets vault-path smaller-vault id fresh)
    (publish-generation generations generation link)
    (sort (scandir link (lambda (f) (not (string-prefix? "." f)))) string<?)))

(test-equal "next-generation is one higher than the highest" #t
  (let ((generations (string-append root "/run/secrets.d")))
    ;; Only the latest generation remains after each publish.
    (and (= 1 (next-generation (string-append root "/run/absent")))
         (let ((highest (fold (lambda (name n)
                                (let ((k (string->number name)))
                                  (if (and k (> k n)) k n)))
                              0
                              (scandir generations))))
           (= (+ 1 highest) (next-generation generations))))))

(test-equal "no plaintext is left in a temporary file" '()
  (filter (lambda (f) (string-contains f ".tmp"))
          (or (scandir live) '())))

(test-equal "ensure-machine-identity makes a private identity and shows its public half" #t
  (let* ((file (string-append root "/etc/guix/secrets/identity.txt"))
         (shown (ensure-machine-identity file)))
    (and (file-exists? file)
         (= #o600 (logand (stat:mode (stat file)) #o777))
         (string-prefix? "age1" shown)
         (string=? shown (ensure-machine-identity file)))))

(test-equal "the canary is in no file of the vault directory but the ciphertext" #t
  (let ((files (find-files vault-path)))
    (every (lambda (file)
             (or (string-suffix? ".age" file)
                 (string-suffix? ".pub" file)
                 (string-suffix? "vault.scm" file)
                 (not (string-contains
                       (call-with-input-file file get-string-all) canary))))
           files)))

;; The activation decision: a generation directory that is not a mount point
;; is not the volatile file system, so activation must defer and write nothing
;; (on Guix System /run is on the root disk; writing before the tmpfs mount
;; would put plaintext on the disk, D9).  A plain directory under the test
;; root has the same stat:dev as its parent, so it is not a mount point.
(test-equal "a generation directory that is not a mount point defers" #f
  (let ((plain (string-append root "/run/not-mounted")))
    (mkdir-p plain)
    (volatile-generation-directory? plain)))

(test-equal "an absent generation directory defers and is not created" #t
  (let ((absent (string-append root "/run/absent-generation")))
    (and (not (volatile-generation-directory? absent))
         (not (file-exists? absent)))))

;; A real mount point has a stat:dev different from its parent.  /dev/shm is a
;; tmpfs mount on the build machine; when it is one, the decision accepts it.
;; (If the environment has no /dev/shm mount the check is skipped, not failed.)
(test-equal "a mounted volatile directory is accepted" #t
  (let ((shm "/dev/shm"))
    (if (and (file-exists? shm)
             (let ((st (stat shm #f))
                   (parent (stat (dirname shm) #f)))
               (and st parent (not (= (stat:dev st) (stat:dev parent))))))
        (volatile-generation-directory? shm)
        #t)))

;; ensure-volatile-directory mounts the tmpfs itself.  As an unprivileged user
;; the mount is refused, so it raises and writes nothing into the directory:
;; it must never leave a non-volatile directory that a later step would
;; materialise plaintext into.  (The test runs unprivileged; the mount needs
;; root, so this exercises the refusal path, not a successful mount.)
(test-equal "ensure-volatile-directory raises unprivileged and writes nothing" #t
  (let ((plain (string-append root "/run/ensure-plain")))
    (mkdir-p plain)
    (and (catch #t
           (lambda () (ensure-volatile-directory plain) #f)
           (lambda (key . args) #t))
         ;; Nothing was materialised into it: it stays an empty plain dir.
         (null? (scandir plain (lambda (f)
                                 (not (member f '("." ".."))))))
         (not (volatile-generation-directory? plain)))))

(test-end)
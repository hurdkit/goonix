;;; goonix: the secrets service on a running system.
;;;
;;; A new file of ours; gnu/tests is not edited except for the marked hook
;;; that lists this module in gnu/local.mk.  The S-4 gate: a test system
;;; boots, the service reads its secret from /run/secrets with the declared
;;; owner and mode, and the canary is in no store item of that system.
;;;
;;; The machine's first identity reaches the guest through the first-boot
;;; copy service Guix already has for virtual machines (gnu build
;;; secret-service): the host makes a throwaway test identity, encrypts the
;;; canary to it, and sends the private half over the forwarded secrets port.
;;; The identity is made on the host at evaluation time and spliced into the
;;; test gexp, so it is in the test derivation's builder (a store item), but
;;; it is NOT in the guest system's closure, which is what the gate checks.
;;; The system closure carries only the ciphertext.
(define-module (gnu tests goonix-secrets)
  #:use-module (gnu tests)
  #:use-module (gnu image)
  #:use-module (gnu system)
  #:use-module (gnu system vm)
  #:use-module (gnu system image)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services ssh)
  #:use-module (gnu services networking)
  #:use-module (gnu services goonix-secrets)
  #:use-module (gnu services virtualization)
  #:use-module (gnu system hurd)
  #:use-module (gnu system shadow)
  #:use-module (gnu system file-systems)
  #:use-module (gnu packages virtualization)
  #:use-module (gnu packages gnupg)
  #:use-module (gnu packages guile-xyz)
  #:use-module (gnu packages ssh)
  #:use-module (guix gexp)
  #:use-module (guix store)
  #:use-module (guix monads)
  #:use-module (guix modules)
  #:use-module (guix self)
  #:use-module ((guix utils) #:select (%current-system %current-target-system))
  #:use-module (guix secrets age)
  #:use-module (guix secrets vault)
  #:use-module (guix secrets materialise)
  #:use-module ((guix build utils) #:select (mkdir-p find-files))
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 binary-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:export (%test-goonix-secrets
            %test-goonix-secrets-hurd))

(define %canary "goonix-s4-system-canary-4c1d8e2a-private")
(define %alice-canary "goonix-s4-system-alice-9b2f7c1d-private")
(define %secrets-port 11004)

(define not-config?
  ;; Select (guix …) and (gnu …) modules, except (guix config).
  (match-lambda
    (('guix 'config) #f)
    (('guix rest ...) #t)
    (('gnu rest ...) #t)
    (_ #f)))

(define (test-vault identity)
  "A vault directory declaring two secrets encrypted to IDENTITY's public key:
one owned by root, one by the non-root user alice that the test system already
has.  The ciphertext is a store item; the canary plaintext is not."
  (let ((public (x25519-identity-public identity)))
    (file-union "secrets-vault"
                `(("vault.scm"
                   ,(plain-file "vault.scm"
                                (format #f "(vault (format 1) (recipients (machine ~s))
 (secrets (token (for machine) (owner \"root\") (mode #o400))
          (alice-token (for machine) (owner \"alice\") (mode #o400))))\n" public)))
                  ("token.age"
                   ,(plain-file "token.age"
                                (encrypt-age (string->utf8 %canary)
                                             (list public))))
                  ("alice-token.age"
                   ,(plain-file "alice-token.age"
                                (encrypt-age (string->utf8 %alice-canary)
                                             (list public))))))))

(define (run-secrets-test)
  (define identity (generate-x25519-identity))
  ;; Build the vault once, outside the operating-system form.  The services
  ;; field is thunked, so a (test-vault identity) call inside it would run
  ;; again on every read, and encrypt-age draws a new random file key each
  ;; time, giving a different vault, system and disk image on every read.
  (define vault (test-vault identity))
  ;; secret-service-type and secret-service-operating-system are not exported
  ;; from (gnu services virtualization); reference them directly.  The guest
  ;; listens for the first-boot copy on port 1004 through secret-service-type,
  ;; the way the childhurd does.
  (define secret-service-os
    (@@ (gnu services virtualization) secret-service-operating-system))
  (define os
    (marionette-operating-system
     (secret-service-os
      (operating-system
        (inherit (simple-operating-system))
        (services
         (cons* (service secrets-service-type
                         (secrets-configuration
                          (vault vault)
                          (first-boot-copy? #t)))
                ;; secret-service-operating-system modifies the openssh
                ;; service, so the system must have one.
                (service openssh-service-type
                         (openssh-configuration
                          (openssh openssh-sans-x)))
                (service static-networking-service-type
                         (list %qemu-static-networking))
                (operating-system-user-services (simple-operating-system))))))
     #:imported-modules '((gnu services herd))))

  ;; The guest listens for the first-boot copy on port 1004; forward it.
  (define vm
    (virtual-machine
     (operating-system os)
     (port-forwardings `((,%secrets-port . 1004)))))

  (define test
    (with-extensions (list guile-gcrypt guile-fibers)
      (with-imported-modules `(((guix config) => ,(make-config.scm))
                               ,@(source-module-closure
                                  '((gnu build marionette)
                                    (gnu build secret-service)
                                    (guix build store-copy)
                                    (guix build utils))
                                  #:select? not-config?))
        #~(begin
            (use-modules (gnu build marionette)
                         (gnu build secret-service)
                         (guix build store-copy)
                         (guix build utils)
                         (ice-9 textual-ports)
                         (ice-9 ftw)
                         (srfi srfi-1)
                         (srfi srfi-64))

            (define marionette
              (make-marionette (list #$vm)))

            (test-runner-current (system-test-runner #$output))
            (test-begin "goonix-secrets")

            ;; Send the machine's first identity through the first-boot copy.
            ;; The private half is written in the build directory and removed
            ;; afterwards; it is a throwaway test identity.
            (test-assert "first-boot identity copy arrives"
              (let* ((root (string-append (getenv "TMPDIR") "/first-boot"))
                     (identity-file
                      (string-append root "/etc/guix/secrets/identity.txt")))
                (mkdir-p (dirname identity-file))
                (call-with-output-file identity-file
                  (lambda (port)
                    (chmod identity-file #o600)
                    (display (string-append "# goonix machine age identity\n"
                                            #$identity "\n")
                             port)))
                (let ((sent (secret-service-send-secrets
                             (make-socket-address AF_INET INADDR_LOOPBACK
                                                  #$%secrets-port)
                             root)))
                  (delete-file-recursively root)
                  sent)))

            (test-assert "secrets service is running"
              (marionette-eval
               '(begin
                  (use-modules (gnu services herd))
                  (start-service 'secrets))
               marionette))

            (test-equal "the secret is materialised with its plaintext"
              #$%canary
              (marionette-eval
               '(begin
                  (use-modules (ice-9 textual-ports))
                  (call-with-input-file "/run/secrets/token" get-string-all))
               marionette))

            (test-equal "the secret has the declared owner and mode"
              '(0 #o400)
              (marionette-eval
               '(let ((st (stat "/run/secrets/token")))
                  (list (stat:uid st) (stat:perms st)))
               marionette))

            (test-equal "/run/secrets is a symlink to a generation"
              #t
              (marionette-eval
               '(begin
                  (use-modules (guix build utils))
                  (and (symbolic-link? "/run/secrets")
                       (string-prefix? "/run/secrets.d/"
                                       (readlink "/run/secrets"))))
               marionette))

            (test-equal "the generation directory is traversable but not listable"
              #o751
              (marionette-eval
               '(logand (stat:perms (stat "/run/secrets")) #o777)
               marionette))

            ;; A secret declared for a non-root user is reachable by that user
            ;; through the 751 generation, and refused to another user.  The
            ;; read runs in a forked child that drops to the user's uid/gid,
            ;; the way the shadow and container tests do it.
            (test-equal "a non-root secret is read by its owner"
              #$%alice-canary
              (marionette-eval
               '(begin
                  (use-modules (ice-9 textual-ports) (ice-9 match))
                  ;; The guest REPL has no TMPDIR; use /tmp as the shadow test
                  ;; does.  The child drops to alice and writes what it reads.
                  ;; It is wrapped in dynamic-wind with a primitive-exit in the
                  ;; after thunk so that, if anything raises (setuid, getpwnam,
                  ;; or the read itself — the regression this check catches),
                  ;; the child still exits instead of answering on the REPL
                  ;; device and looping, which would leave two processes reading
                  ;; the virtio port and hang the parent's waitpid.
                  (let ((out "/tmp/goonix-alice-read"))
                    (match (primitive-fork)
                      (0
                       (dynamic-wind
                         (const #f)
                         (lambda ()
                           (setgroups #())
                           (setgid (passwd:gid (getpwnam "alice")))
                           (setuid (passwd:uid (getpwnam "alice")))
                           (call-with-output-file out
                             (lambda (port)
                               (display
                                (call-with-input-file "/run/secrets/alice-token"
                                  get-string-all)
                                port)))
                           (primitive-exit 0))
                         (lambda () (primitive-exit 127))))
                      (pid
                       (let ((status (cdr (waitpid pid))))
                         (and (zero? status)
                              (call-with-input-file out get-string-all)))))))
               marionette))

            (test-assert "a non-root secret is refused to another user"
              (marionette-eval
               '(begin
                  (use-modules (ice-9 match))
                  (match (primitive-fork)
                    (0
                     (dynamic-wind
                       (const #f)
                       (lambda ()
                         ;; Drop the REPL's (root's) supplementary groups too,
                         ;; so this really tests an unprivileged user.  nobody
                         ;; (uid 65534) owns nothing and may not read alice's
                         ;; secret.
                         (setgroups #())
                         (setgid 65534)
                         (setuid 65534)
                         (primitive-exit
                          (if (false-if-exception
                               (call-with-input-file "/run/secrets/alice-token"
                                 get-string-all))
                              1 0)))
                       (lambda () (primitive-exit 127))))
                    (pid (zero? (cdr (waitpid pid))))))
               marionette))

            ;; The gate: the canary is in no store item of the system.  The
            ;; reference graph of the system is read on the host (in this
            ;; build), so every item of the closure is checked, not just the
            ;; files of the system directory.  A dangling symlink (nss-certs
            ;; has a few) has no stat, so it is skipped, not an error.
            (test-assert "the canary is in no store item of the system"
              (let ((items (call-with-input-file "system-closure"
                             read-reference-graph)))
                (every (lambda (info)
                         (let ((item (store-info-item info)))
                           (every (lambda (file)
                                    (let ((st (stat file #f)))
                                      (or (not st)
                                          (not (eq? 'regular (stat:type st)))
                                          (let ((content
                                                 (call-with-input-file file
                                                   get-string-all)))
                                            (and (not (string-contains
                                                       content #$%canary))
                                                 (not (string-contains
                                                       content #$%alice-canary)))))))
                                  (if (file-is-directory? item)
                                      (find-files item)
                                      (list item)))))
                       items)))

            (test-end)))))
  (gexp->derivation "goonix-secrets-test" test
                    #:references-graphs `(("system-closure" ,os))))

(define %test-goonix-secrets
  (system-test
   (name "goonix-secrets")
   (description "Boot a system with the secrets service, send its first
identity through the first-boot copy, and check that the secret is
materialised in /run/secrets with its declared owner and mode while the
canary is in no store item of the system.")
   (value (run-secrets-test))))

;;;
;;; The same on a GNU/Hurd guest (a childhurd): the S-4 gate's second half.
;;;
;;; A Hurd VM with the secrets service runs inside a Linux VM (the childhurd
;;; model of gnu/tests/virtualization.scm).  The Hurd's first identity reaches
;;; it through the first-boot copy service: the Linux guest's activation writes
;;; a throwaway identity into the childhurd's secret-root before the childhurd
;;; shepherd service starts and sends it to the Hurd (guest port 1004,
;;; forwarded to 11004 in the Linux guest).  The checks run over SSH to the
;;; Hurd (port 10022, user "test").  The guest-side check that stat:dev of the
;;; translated /run/secrets.d differs from /run is here, not in the unit test:
;;; only a running Hurd shows that the tmpfs translator made a separate file
;;; system.
;;;

(define %hurd-canary "goonix-s4-hurd-canary-5d8a2f9c-private")
(define %hurd-root-canary "goonix-s4-hurd-root-canary-6e9b3a1d-private")
(define %hurd-secrets-port 11004)
(define %hurd-ssh-port 10022)

(define (hurd-test-vault identity)
  "A vault declaring two secrets encrypted to IDENTITY's public key, for the
Hurd guest: a token owned by 'test' (the SSH reader) and a root-token owned by
root, mode 400.  The root-owned one is the evidence that the Hurd tmpfs
translator enforces the mode: 'test' must not be able to read it.  The
ciphertexts are store items; the canary plaintexts are not."
  (let ((public (x25519-identity-public identity)))
    (file-union "secrets-vault"
                `(("vault.scm"
                   ,(plain-file "vault.scm"
                                (format #f "(vault (format 1) (recipients (machine ~s))
 (secrets (token (for machine) (owner \"test\") (mode #o400))
          (root-token (for machine) (owner \"root\") (mode #o400))))\n" public)))
                  ("token.age"
                   ,(plain-file "token.age"
                                (encrypt-age (string->utf8 %hurd-canary)
                                             (list public))))
                  ("root-token.age"
                   ,(plain-file "root-token.age"
                                (encrypt-age (string->utf8 %hurd-root-canary)
                                             (list public))))))))

(define* (run-hurd-command-over-ssh command #:key (port %hurd-ssh-port)
                                    (user "test"))
  "Return a program that runs COMMAND in the Hurd guest over SSH and prints
the result on standard output, the way the childhurd test does.  The user is
'test' (empty password); the secret it reads is declared owned by 'test'."
  (program-file "run-hurd-command-over-ssh"
                (with-extensions (list guile-ssh)
                  #~(begin
                      (use-modules (ssh session) (ssh auth) (ssh popen)
                                   (ice-9 match) (ice-9 textual-ports))
                      (let ((session (make-session #:user #$user
                                                   #:port #$port
                                                   #:host "localhost"
                                                   #:timeout 120
                                                   #:log-verbosity 'rare)))
                        (match (connect! session)
                          ('ok
                           (userauth-password! session "")
                           (display
                            (get-string-all
                             (open-remote-input-pipe* session #$@command))))
                          (status
                           (error "could not connect to Hurd guest over SSH"
                                  session status))))))))

(define (run-secrets-hurd-test)
  (define identity (generate-x25519-identity))
  ;; Build the vault once, outside the operating-system form (thunked services).
  (define vault (hurd-test-vault identity))
  (define secret-service-os
    (@@ (gnu services virtualization) secret-service-operating-system))

  ;; The Hurd guest: the secrets service with a first-boot copy, and a "test"
  ;; user with an empty password for SSH.  hurd-vm-disk-image wraps this with
  ;; secret-service-operating-system, so it listens for the identity on 1004.
  (define hurd-os
    (operating-system
      (inherit %hurd-vm-operating-system)
      ;; A root file system, as hurd-barebones-os has, so the system closure
      ;; can be read through #:references-graphs for the canary gate.
      (file-systems (cons (file-system
                            (device (file-system-label "my-root"))
                            (mount-point "/")
                            (type "ext2"))
                          %base-file-systems))
      (users (cons (user-account
                    (name "test")
                    (group "users")
                    (uid 1000)
                    (password ""))
                   %base-user-accounts))
      (services
       (cons (service secrets-service-type
                      (secrets-configuration
                       (vault vault)
                       (first-boot-copy? #t)))
             (operating-system-user-services %hurd-vm-operating-system)))))

  ;; The Hurd OS as it actually boots: hurd-vm-disk-image wraps it with
  ;; secret-service-operating-system, which provides secret-service-client
  ;; (the 'secrets' service requires it with first-boot-copy?).  The reference
  ;; graph for the canary gate is of this wrapped system.
  (define hurd-boot-os (secret-service-os hurd-os))

  ;; The Linux guest runs the childhurd.  Its activation writes the throwaway
  ;; identity into the childhurd's secret-root before the childhurd starts and
  ;; sends it to the Hurd.  The private half is spliced into this gexp (a store
  ;; item of the test builder), but NOT into the Hurd system's closure.
  (define os
    (marionette-operating-system
     (simple-operating-system
      (service dhcpcd-service-type)
      (simple-service 'goonix-hurd-identity activation-service-type
                      #~(begin
                          (use-modules (guix build utils))
                          (let ((file "/etc/childhurd/etc/guix/secrets/identity.txt"))
                            (mkdir-p (dirname file))
                            (call-with-output-file file
                              (lambda (port)
                                (chmod file #o600)
                                (display (string-append
                                          "# goonix machine age identity\n"
                                          #$identity "\n")
                                         port))))
                          #t))
      (service hurd-vm-service-type
               (hurd-vm-configuration
                (type 'hurd64-qcow2)
                (os hurd-os)
                (offloading? #f))))
     #:imported-modules (source-module-closure
                         '((gnu services herd)
                           (guix combinators))
                         #:select? not-config?)))

  (define vm
    (virtual-machine
     (operating-system os)
     (memory-size (* 1024 3))))

  ;; SSH programs built at host time for fixed commands run in the Hurd guest.
  ;; The test-owned token is read with a bare 'cat' (the earlier sh -c wrapper
  ;; was a workaround for a problem that never existed: the real cause was
  ;; reading a root-owned 0400 file as the non-root 'test' user).
  (define cat-token (run-hurd-command-over-ssh
                     '("cat" "/run/secrets/token")))
  (define stat-token (run-hurd-command-over-ssh
                      '("stat" "-c" "%u %a" "/run/secrets/token")))
  ;; The root-owned secret: one shell command reports its byte count and
  ;; owner/mode via stat (metadata is readable through the 751 generation
  ;; traversal; opening the file for reading is what must fail), then attempts
  ;; the read as 'test'.  The denial check compares the read output against the
  ;; stat size, so an empty file cannot make it pass trivially.
  (define root-token-probe (run-hurd-command-over-ssh
                            '("sh" "-c"
                              "echo size=$(stat -c %s /run/secrets/root-token); echo owner=$(stat -c '%u %a' /run/secrets/root-token); echo read=[$(cat /run/secrets/root-token 2>&1)]")))
  (define readlink-secrets (run-hurd-command-over-ssh
                            '("readlink" "/run/secrets")))
  (define dev-check (run-hurd-command-over-ssh
                     '("sh" "-c"
                       "test \"$(stat -c %d /run/secrets.d)\" != \"$(stat -c %d /run)\" && echo separate")))
  ;; Wait until the secrets service has materialised the token (it runs
  ;; asynchronously after the first-boot identity arrives).  Poll in the Hurd
  ;; guest until /run/secrets/token is a non-empty regular file.
  (define wait-secret (run-hurd-command-over-ssh
                       '("sh" "-c"
                         "i=0; while [ $i -lt 120 ]; do if [ -s /run/secrets/token ]; then echo ready; exit 0; fi; i=$((i+1)); sleep 1; done; echo timeout")))

  (define test
    (with-extensions (list guile-gcrypt guile-fibers)
      (with-imported-modules `(((guix config) => ,(make-config.scm))
                               ,@(source-module-closure
                                  '((gnu build marionette)
                                    (guix build store-copy)
                                    (guix build utils))
                                  #:select? not-config?))
        #~(begin
            (use-modules (gnu build marionette)
                         (guix build store-copy)
                         (guix build utils)
                         (ice-9 textual-ports)
                         (ice-9 popen)
                         (ice-9 match)
                         (ice-9 regex)
                         (srfi srfi-1)
                         (srfi srfi-64))

            (define marionette
              (make-marionette (list #$vm "-cpu" "max")))

            (test-runner-current (system-test-runner #$output))
            (test-begin "goonix-secrets-hurd")

            (test-assert "childhurd service running"
              (marionette-eval
               '(begin
                  (use-modules (gnu services herd) (ice-9 match))
                  (match (start-service 'childhurd)
                    (#f #f)
                    (('service response-parts ...)
                     (match (assq-ref response-parts 'running)
                       ((pid) pid)))))
               marionette))

            ;; Wait for the Hurd's SSH server, then run a command in it.  The
            ;; SSH programs are built at host time (below) for fixed commands;
            ;; hurd-ssh runs one in the Linux guest, which forwards to the Hurd.
            (define (hurd-ssh prog)
              (marionette-eval
               `(begin
                  (use-modules (ice-9 popen) (ice-9 textual-ports))
                  (get-string-all (open-input-pipe ,prog)))
               marionette))

            (test-assert "Hurd SSH server replies"
              (marionette-eval
               '(begin
                  (use-modules (ice-9 match) (ice-9 textual-ports))
                  (let loop ((n 120))
                    (if (zero? n)
                        #f
                        (let ((s (socket PF_INET SOCK_STREAM 0))
                              (a (make-socket-address AF_INET
                                                      INADDR_LOOPBACK
                                                      #$%hurd-ssh-port)))
                          (connect s a)
                          (match (get-string-n s 3)
                            ((? eof-object?)
                             (close-port s) (sleep 1) (loop (- n 1)))
                            (str (close-port s)
                                 (string-prefix? "SSH" str)))))))
               marionette))

            ;; The secrets service materialises asynchronously after the
            ;; first-boot identity arrives; wait for the token to be present.
            (test-assert "the secrets service materialises the token"
              (string=? "ready"
                        (string-trim-both (hurd-ssh #$wait-secret))))

            (test-equal "the secret is materialised in the Hurd"
              #$%hurd-canary
              (hurd-ssh #$cat-token))

            ;; The root-owned 0400 secret: 'test' must NOT be able to read it.
            ;; This is the evidence that the Hurd tmpfs translator enforces the
            ;; mode (D9 relies on it; the Linux test does not cover it on the
            ;; Hurd).  The probe reports the stat size and owner/mode (metadata
            ;; readable through the generation traversal) and the read output.
            ;; The check requires a non-empty root-owned 0400 file whose read
            ;; yields neither the canary nor its full byte count, so an empty
            ;; file or a successful read cannot make it pass trivially.
            (test-assert "test cannot read the root-owned secret (mode enforced)"
              (let* ((out (hurd-ssh #$root-token-probe))
                     (size-m (string-match "size=([0-9]+)" out))
                     (owner-m (string-match "owner=([0-9]+ [0-9]+)" out))
                     (read-m (string-match "read=\\[(.*)\\]" out))
                     (size (and size-m (string->number (match:substring size-m 1))))
                     (owner (and owner-m (match:substring owner-m 1)))
                     (read-out (if read-m (match:substring read-m 1) "")))
                (format #t "root-token probe: ~a~%" out)
                (and size (> size 0)
                     (string=? "0 400" owner)
                     (not (string-contains read-out #$%hurd-root-canary))
                     (not (= (string-length read-out) size)))))

            (test-equal "the secret has the declared owner and mode in the Hurd"
              "1000 400\n"
              (hurd-ssh #$stat-token))

            (test-assert "/run/secrets is a symlink to a generation in the Hurd"
              (string-prefix? "/run/secrets.d/"
                              (string-trim-both
                               (hurd-ssh #$readlink-secrets))))

            ;; The guest-side check the unit test cannot show: the tmpfs
            ;; translator made /run/secrets.d a separate file system, so its
            ;; stat:dev differs from /run's.  Both stats run in the Hurd guest
            ;; in one shell command; the program is built at host time.
            (test-assert "the translated /run/secrets.d is a separate file system"
              (string=? "separate"
                        (string-trim-both (hurd-ssh #$dev-check))))

            ;; The gate: neither canary (the test-owned token's nor the
            ;; root-owned one's) is in any store item of the Hurd system.
            (test-assert "the canary is in no store item of the Hurd system"
              (let ((items (call-with-input-file "hurd-system-closure"
                             read-reference-graph)))
                (every (lambda (info)
                         (let ((item (store-info-item info)))
                           (every (lambda (file)
                                    (let ((st (stat file #f)))
                                      (or (not st)
                                          (not (eq? 'regular (stat:type st)))
                                          (let ((content (call-with-input-file file
                                                           get-string-all)))
                                            (and (not (string-contains content
                                                                       #$%hurd-canary))
                                                 (not (string-contains content
                                                                       #$%hurd-root-canary)))))))
                                  (if (file-is-directory? item)
                                      (find-files item)
                                      (list item)))))
                       items)))

            (test-end)))))
  ;; The reference graph is lowered in the test gexp's context (x86_64-linux,
  ;; native), which would build the Hurd packages natively on Linux and fail
  ;; (libirqhelp: "host cannot be linux-gnu").  with-parameters sets the cross
  ;; target only, as system-image does for the disk image: %current-system
  ;; stays the host so fixed-output source downloads build on it, while the
  ;; packages cross-compile to the Hurd.  (Setting %current-system to
  ;; x86_64-gnu would make the source derivations require a Hurd builder.)
  (gexp->derivation "goonix-secrets-hurd-test" test
                    #:references-graphs
                    `(("hurd-system-closure"
                       ,(with-parameters ((%current-target-system "x86_64-pc-gnu"))
                          hurd-boot-os)))))

(define %test-goonix-secrets-hurd
  (system-test
   (name "goonix-secrets-hurd")
   (description "Boot a GNU/Hurd guest (a childhurd) with the secrets service,
send its first identity through the first-boot copy, and check that the secret
is materialised in /run/secrets with its declared owner and mode, that the
'test' user can read its own secret but not a root-owned 0400 one (the Hurd
tmpfs translator enforces the mode), that the translated /run/secrets.d is a
separate file system, and that the canaries are in no store item of the Hurd
system.")
   (value (run-secrets-hurd-test))))
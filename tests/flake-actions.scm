;;; goonix: tests for the commands that take a flake reference.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (test-flake-actions)
  #:use-module (guix store)
  #:use-module (guix derivations)
  #:use-module (guix tests)
  #:use-module (guix tests git)
  #:use-module ((guix config) #:select (%state-directory))
  #:use-module ((guix diagnostics) #:select (formatted-message?
                                             formatted-message-string
                                             formatted-message-arguments))
  #:use-module ((guix profiles) #:select (generation-numbers))
  #:use-module ((guix pure-eval) #:select (pure-eval-supported?))
  #:use-module ((guix utils) #:select (call-with-temporary-directory))
  #:use-module ((guix build utils) #:select (mkdir-p))
  #:use-module (guix flakes evaluate)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-34)
  #:use-module (srfi srfi-64))

(test-begin "flake-actions")

(define %store (open-connection-for-tests))

;; The evaluator runs in a container.
(unless (pure-eval-supported?)
  (test-skip 100))

(define (call-with-flake text proc)
  "Call PROC with a checkout whose flake.scm holds TEXT."
  (call-with-temporary-directory
   (lambda (directory)
     (with-git-repository directory
         `((add "flake.scm" ,text) (commit "a flake"))
       (proc directory)))))

(define-syntax-rule (raises? body ...)
  (guard (condition (#t #t))
    body ...
    #f))


;;;
;;; 'guix shell'.
;;;
;;; Only the derivation of the profile and the variables come back.  These
;;; tests build the profiles and look inside, so a shell that ignored its
;;; name or its packages fails.

(define %shells
  (call-with-input-file "tests/fixtures/flake-shells.scm" get-string-all))

(define (shell-profile directory name . rest)
  "Return the built profile of the shell NAME and its variables."
  (let-values (((drv environment)
                (apply evaluate-flake-shell %store directory name
                       #:bootstrap? #t rest)))
    (build-derivations %store (list drv))
    (values (derivation->output-path drv) environment)))

(define (in-profile? profile tool)
  (file-exists? (string-append profile "/bin/" tool)))

(test-assert "a shell is the profile of its packages, with its variables"
  (call-with-flake %shells
    (lambda (directory)
      (let-values (((profile environment) (shell-profile directory 'default)))
        (and (equal? '(("FLAKE_SHELL" . "default")) environment)
             (in-profile? profile "flake-tool-one")
             (not (in-profile? profile "flake-tool-two")))))))

(test-assert "another name selects another shell"
  (call-with-flake %shells
    (lambda (directory)
      (let-values (((profile environment) (shell-profile directory 'other)))
        (and (null? environment)
             (in-profile? profile "flake-tool-two")
             (not (in-profile? profile "flake-tool-one")))))))

(test-assert "a package that is no shell is entered as a shell of itself"
  (call-with-flake %shells
    (lambda (directory)
      (let-values (((profile environment) (shell-profile directory 'tool)))
        (in-profile? profile "flake-tool-two")))))

(test-assert "the development environment of a package leaves the package out"
  (call-with-flake %shells
    (lambda (directory)
      (let-values (((profile environment)
                    (shell-profile directory 'tool #:development? #t)))
        (not (in-profile? profile "flake-tool-two"))))))

(test-assert "a missing shell is an error unless it is optional"
  (call-with-flake %shells
    (lambda (directory)
      (and (not (evaluate-flake-shell %store directory 'missing
                                      #:optional? #t #:bootstrap? #t))
           (raises? (evaluate-flake-shell %store directory 'missing
                                          #:bootstrap? #t))))))


;;;
;;; 'guix run': an app of that name, else a package.
;;;

(define %apps
  "(flake (format 1)
 (outputs (lambda (in)
  (use-modules (guix) (guix build-system trivial) (gnu packages bootstrap))
  (define (tool name)
    (package
      (name name) (version \"0\") (source #f)
      (build-system trivial-build-system)
      (arguments (list #:guile %bootstrap-guile
                       #:builder #~(mkdir #$output)))
      (home-page #f) (synopsis #f) (description #f) (license #f)))
  `((packages (both . ,(tool \"package-both\"))
              (only . ,(tool \"package-only\")))
    (apps (both . ,(tool \"app-both\")))))))")

(test-equal "an output is looked for among kinds in order"
  '("app-both-0.drv" "package-only-0.drv")
  (call-with-flake %apps
    (lambda (directory)
      (map (lambda (name)
             (string-drop
              (basename
               (derivation-file-name
                (evaluate-flake %store directory '(apps packages) name)))
              33))
           '(both only)))))


;;;
;;; 'guix system', 'guix home' and 'guix deploy'.
;;;

(define (system-flake host-name)
  "Return the text of a flake whose 'systems' output 'box' has HOST-NAME, an
expression, as its host name; 'machines' deploys it twice."
  (format #f "(flake (format 1)
 (outputs (lambda (in)
  (use-modules (gnu) (gnu machine) (gnu machine ssh))
  (define box
    (operating-system
      (host-name ~a)
      (timezone \"Europe/Paris\")
      (locale \"en_US.UTF-8\")
      (bootloader (bootloader-configuration
                    (bootloader grub-bootloader)
                    (targets (list \"/dev/sdX\"))))
      (file-systems (cons (file-system
                            (device (file-system-label \"root\"))
                            (mount-point \"/\")
                            (type \"ext4\"))
                          %base-file-systems))))
  (define (machine-at host)
    (machine
      (operating-system box)
      (environment managed-host-environment-type)
      (configuration (machine-ssh-configuration
                       (host-name host) (system \"x86_64-linux\")))))
  `((systems (box . ,box))
    (machines (fleet . ,(list (machine-at \"one.example.org\")
                              (machine-at \"two.example.org\"))))))))"
          host-name))

(define (suffixes names)
  (map (lambda (name) (string-drop (basename name) 33)) names))

(test-equal "an action of 'guix system' is carried out on a flake output"
  '(("system.drv") ("image.iso.drv") #f)
  (call-with-flake (system-flake "\"antelope\"")
    (lambda (directory)
      (let ((build (evaluate-flake-command %store directory 'system
                                           '(systems) 'box
                                           '("build" "--no-grafts")))
            (image (evaluate-flake-command %store directory 'system
                                           '(images systems) 'box
                                           '("image" "-t" "iso9660"
                                             "--no-grafts"))))
        (list (suffixes build) (suffixes image)
              (equal? build image))))))

(test-equal "what 'guix deploy' would deploy is the system of each machine"
  '("system.drv" "system.drv")
  (call-with-flake (system-flake "\"antelope\"")
    (lambda (directory)
      (suffixes
       (evaluate-flake-command %store directory 'deploy
                               '(machines) 'fleet '("--no-grafts"))))))

;; The gate of the commands that act.  The action here is 'build' with
;; '--dry-run', which changes nothing; what is under test is whether the
;; second run, outside the container, is let through.
(define (act directory)
  (evaluate-flake-command %store directory 'system '(systems) 'box
                          '("build" "--dry-run" "--no-grafts")
                          #:act? #t))

(test-assert "a command acts when inside and outside agree"
  (call-with-flake (system-flake "\"antelope\"")
    (lambda (directory)
      (pair? (act directory)))))

(test-assert "a command does not act when outside differs from inside"
  ;; The host name is read from the environment: the container has none.
  (call-with-flake (system-flake "(or (getenv \"FLAKE_HOST\") \"inside\")")
    (lambda (directory)
      (dynamic-wind
        (lambda () (setenv "FLAKE_HOST" "outside"))
        (lambda () (raises? (act directory)))
        (lambda () (unsetenv "FLAKE_HOST"))))))

;; The reconfigure action ITSELF, not 'build --dry-run'.  Reconfigure is one of
;; the actions that change a machine (flake-command-action sets acting? for
;; 'reconfigure and 'init), so it goes through the same pure/acting comparison.
;; Here the outside evaluation differs (the host name comes from the
;; environment, which the container has none of), so the action must be refused
;; with the "not carrying this out" message BEFORE anything acts: no activation,
;; no profile switch, no generation written.  Only the refusal path is tested;
;; acting needs root.
(define (reconfigure directory)
  (evaluate-flake-command %store directory 'system '(systems) 'box
                          '("reconfigure" "--no-grafts" "--skip-checks"
                            "--no-bootloader")
                          #:act? #t))

(test-assert "reconfigure refuses when the pure and the acting derivation differ"
  (call-with-flake (system-flake "(or (getenv \"FLAKE_HOST\") \"inside\")")
    (lambda (directory)
      (define system-profile
        (string-append %state-directory "/profiles/system"))
      (define generations-before (generation-numbers system-profile))
      (define current-system-before
        (false-if-exception (readlink "/run/current-system")))
      (dynamic-wind
        (lambda () (setenv "FLAKE_HOST" "outside"))
        (lambda ()
          (let ((refused
                 (guard (condition
                         ((formatted-message? condition)
                          (apply simple-format #f
                                 (formatted-message-string condition)
                                 (formatted-message-arguments condition)))
                         (#t #f))
                   (reconfigure directory)
                   #f)))
            (and (string? refused)
                 (string-contains refused "not carrying this out")
                 ;; Nothing acted: no generation was written, the system
                 ;; profile is untouched, and /run/current-system did not move.
                 (equal? (generation-numbers system-profile)
                         generations-before)
                 (equal? (false-if-exception (readlink "/run/current-system"))
                         current-system-before))))
        (lambda () (unsetenv "FLAKE_HOST"))))))

(test-end "flake-actions")

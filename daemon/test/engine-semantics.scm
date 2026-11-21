;; HS-4 engine semantics: real requests and observable process/event order.
(use-modules (guix store) (guix derivations) (guix tests)
             (gnu packages bootstrap) (srfi srfi-34) (ice-9 rdelim))
(define fixture (getenv "HS4_SCHEDULER_FIXTURE"))
(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options store #:use-substitutes? #f #:offload? #f #:max-build-jobs 2)
(%graft? #f)
(define shell (add-to-store store "bash" #t "sha256"
               (search-bootstrap-binary "bash" "x86_64-linux")))
(define (script name text)
  (add-text-to-store store (string-append name ".sh") text))
(define (drv name text inputs)
  (let ((body (script name text)))
    (derivation store name shell (list "-e" body)
                #:sources (list shell body)
                #:inputs (map (lambda (input)
                                (if (derivation? input) (derivation-input input) input)) inputs)
                #:outputs (if (equal? name "shared-outputs") '("out" "doc") '("out")))))

;; A valid parent must not load or build an absent input derivation.
(define lazy-child
  (drv "lazy-child"
       (string-append "printf ran >> '" fixture "/lazy-child-ran'\nprintf child > $out\n")
       '()))
(build-derivations store (list lazy-child))
(define lazy-parent
  (drv "lazy-parent" "printf parent > $out\n" (list lazy-child)))
(build-derivations store (list lazy-parent))
(close-connection store)
;; C++ also refuses this deletion while the setup connection holds its goal
;; roots. Close setup first, then delete only the child on a fresh connection;
;; the valid parent output remains usable without loading its input goal.
(let ((deletion-client (open-connection (getenv "GUIX_DAEMON_SOCKET"))))
  (delete-paths deletion-client (list (derivation->output-path lazy-child)))
  (close-connection deletion-client))
(define store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options store #:use-substitutes? #f #:offload? #f #:max-build-jobs 2)
(when (file-exists? (string-append fixture "/lazy-child-ran"))
  (delete-file (string-append fixture "/lazy-child-ran")))
(build-derivations store (list lazy-parent))
(when (file-exists? (string-append fixture "/lazy-child-ran"))
  (error "valid parent eagerly built its input"))
(format #t "HS-4 valid parent is lazy: PASS~%")

;; A substituted parent likewise stops before loading its absent input. The
;; missing builder's marker must remain absent; only the parent's NAR arrives.
(define substitute-store (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options substitute-store #:use-substitutes? #t #:offload? #f
                   #:substitute-urls (%test-substitute-urls) #:max-build-jobs 1)
(define substitute-child
  (let ((body (add-text-to-store substitute-store "substitute-child.sh"
                (string-append "printf ran >> '" fixture "/substitute-child-ran'\nprintf child > $out\n"))))
    (derivation substitute-store "substitute-child" shell (list "-e" body)
                #:sources (list shell body))))
(define substitute-parent
  (let ((body (add-text-to-store substitute-store "substitute-parent.sh"
                "printf parent > $out\n")))
    (derivation substitute-store "substitute-parent" shell (list "-e" body)
                #:sources (list shell body) #:inputs (list (derivation-input substitute-child)))))
(with-derivation-substitute substitute-parent "substituted parent\n"
  (build-derivations substitute-store (list substitute-parent)))
(unless (valid-path? substitute-store (derivation->output-path substitute-parent))
  (error "parent substitute was not registered"))
(when (file-exists? (string-append fixture "/substitute-child-ran"))
  (error "substituted parent eagerly built its input"))
(when (valid-path? substitute-store (derivation->output-path substitute-child))
  (error "substituted parent eagerly fetched its input"))
(format #t "HS-4 substituted parent is lazy: PASS~%")
(close-connection substitute-store)

;; Two dependents select different outputs of one derivation. Neither output
;; exists; both dependents must build and the shared builder must run once.
(define shared
  (drv "shared-outputs"
       (string-append "printf run >> '" fixture "/shared-runs'\nprintf out > $out\nprintf doc > $doc\n")
       '()))
;; The parents select out and doc respectively.
(define left-selected
  (derivation store "left-selected" shell
              (list "-e" (script "left-selected" "printf left > $out\n"))
              #:sources (list shell) #:inputs (list (derivation-input shared '("out")))))
(define right-selected
  (derivation store "right-selected" shell
              (list "-e" (script "right-selected" "printf right > $out\n"))
              #:sources (list shell) #:inputs (list (derivation-input shared '("doc")))))
(build-derivations store (list left-selected right-selected))
(unless (and (valid-path? store (derivation->output-path left-selected))
             (valid-path? store (derivation->output-path right-selected)))
  (error "selected-output union did not build both dependents"))
(unless (= 1 (length (call-with-input-file (string-append fixture "/shared-runs")
                       (lambda (port)
                         (let loop ((lines '()) (line (read-line port)))
                           (if (eof-object? line) (reverse lines)
                               (loop (cons line lines) (read-line port))))))))
  (error "shared derivation ran more than once"))
(format #t "HS-4 selected-output union: PASS~%")

;; One builder fails, the other cannot finish until the test releases it.
;; Without keep-going the client must receive failure before that release.
(define failing
  (drv "failing-builder"
       (string-append
         "while ! test -e '" fixture "/waiting-ready'; do\n"
         "  if read -t 1 _ < '" fixture "/tick'; then :; fi\n"
         "done\n"
         "printf failed-start >> '" fixture "/failure-events'\nexit 1\n")
       '()))
(define waiting
  (drv "waiting-builder"
       (string-append
         "printf waiting-start >> '" fixture "/failure-events'\n"
         "printf started > '" fixture "/waiting-start'\n"
         "printf '%s\\n' $$ > '" fixture "/waiting-pid'\n"
         "printf ready > '" fixture "/waiting-ready'\n"
         "while ! test -e '" fixture "/release-waiting'; do\n"
         "  if read -t 1 _ < '" fixture "/tick'; then :; fi\n"
         "done\n"
         "printf waiting-end >> '" fixture "/failure-events'\n"
         "printf done > $out\n")
       '()))
(define (expect-failure thunk)
  (guard (condition ((store-protocol-error? condition) condition))
    (thunk)
    (error "expected build failure")))
(expect-failure (lambda () (build-derivations store (list failing waiting))))
(when (file-exists? (string-append fixture "/release-waiting"))
  (error "invalid failure fixture"))
(when (file-exists? (string-append fixture "/waiting-ended"))
  (error "waiting builder ended before client failure"))
(call-with-output-file (string-append fixture "/release-waiting") (lambda (port) (display "release\n" port)))
(format #t "HS-4 failure before waiting builder release: PASS~%")

;; Keep-going waits for the independent builder. The fixture writes its own
;; release file in the waiting builder when keep-going is selected.
(define keep-going (open-connection (getenv "GUIX_DAEMON_SOCKET")))
(set-build-options keep-going #:use-substitutes? #f #:offload? #f #:max-build-jobs 2 #:keep-going? #t)
(define keep-failing
  (let ((body (script "keep-failing" "exit 1\n")))
    (derivation keep-going "keep-failing" shell (list "-e" body) #:sources (list shell body))))
(define keep-waiting
  (let ((body (script "keep-waiting"
                 (string-append "printf keep-waiting > $out\n"))))
    (derivation keep-going "keep-waiting" shell (list "-e" body) #:sources (list shell body))))
(expect-failure (lambda () (build-derivations keep-going (list keep-failing keep-waiting))))
(unless (valid-path? keep-going (derivation->output-path keep-waiting))
  (error "keep-going did not finish independent builder"))
(format #t "HS-4 keep-going completes independent builder: PASS~%")
(close-connection keep-going)

;; C++ refuses a local build with no build slots instead of waiting forever.
(set-build-options store #:use-substitutes? #f #:offload? #f #:max-build-jobs 0)
(expect-failure (lambda () (build-derivations store (list lazy-parent))))
(format #t "HS-4 zero local slots: PASS~%")
(close-connection store)

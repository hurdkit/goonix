;;; goonix: CA-2 chain-cutoff and output-placeholder gate.
;;; Included by ca-build.scm after its helpers and test-begin.
(test-group "identical dependency content cuts off the downstream chain"
  (let* ((a-name (fresh-name "ca-a"))
         (b-name (fresh-name "ca-b"))
         (c-name (fresh-name "ca-c"))
         (a1 (shell-drv a-name (write-output "A") #:env-vars '(("v" . "1"))))
         (a2 (shell-drv a-name (write-output "A") #:env-vars '(("v" . "2"))))
         (b (lambda (a)
              (shell-drv b-name
                         "(call-with-output-file out (lambda (p) (display (call-with-input-file (car inputs) (lambda (port) (read-all port))) p) (display \"B\" p)))"
                         #:inputs `((,a)))))
         (c (lambda (b)
              (shell-drv c-name
                         "(call-with-output-file out (lambda (p) (display (call-with-input-file (car inputs) (lambda (port) (read-all port))) p) (display \"C\" p)))"
                         #:inputs `((,b)))))
         (b1 (b a1)) (b2 (b a2)) (c1 (c b1)) (c2 (c b2)))
    (let ((first-log (build-recording-events (list a1)))
          (first-chain-log (build-recording-events (list c1))))
      (build-derivations store (list a2))
      (test-equal "both A recipes resolve to the same content"
        (realised a1) (realised a2))
      (test-equal "first chain builds B once"
        1 (count-build-started first-chain-log (resolved-derivation-for b1)))
      (test-equal "first chain builds C once"
        1 (count-build-started first-chain-log (resolved-derivation-for c1)))
      (let ((second-chain-log (build-recording-events (list c2))))
        (test-equal "B2 has the same resolved derivation as B1"
          (resolved-derivation-for b1) (resolved-derivation-for b2))
        (test-equal "C2 has the same resolved derivation as C1"
          (resolved-derivation-for c1) (resolved-derivation-for c2))
        (test-equal "second chain builds neither B nor C"
          0 (+ (count-build-started second-chain-log
                                    (resolved-derivation-for b2))
               (count-build-started second-chain-log
                                    (resolved-derivation-for c2))))
        (test-equal "second chain uses the first chain's output"
          (realised c1) (realised c2))
        (test-equal "cutoff result content"
          "ABC" (read-all (realised c2)))))))

(test-group "unresolved placeholders are refused at resolution and in outputs"
  (let* ((a (shell-drv "ca-placeholder-input" (write-output "A")))
         (unresolved (placeholder (derivation->bytevector a) "out"
                                  "ca-placeholder-input"))
         (placeholder-parts (list (substring unresolved 0 24)
                                  (substring unresolved 24)))
         (in-input (shell-drv "ca-placeholder-in-recipe"
                              (string-append "(call-with-output-file out "
                                             "(lambda (p) (display \""
                                             unresolved "\" p)))")))
         (in-output (shell-drv "ca-placeholder-output"
                               (string-append
                                "(call-with-output-file out (lambda (p) (display (string-append "
                                (object->string (car placeholder-parts)) " "
                                (object->string (cadr placeholder-parts)) ") p)))"))))
    (test-equal "a placeholder in the input recipe is refused during resolution"
      "unresolved placeholder"
      (and (protocol-error-matching? in-input "unresolved placeholder")
           "unresolved placeholder"))
    (test-equal "a placeholder created by the builder is refused by the output scanner"
      "unresolved goonix placeholder"
      (build-fails-with? in-output "unresolved goonix placeholder"))))



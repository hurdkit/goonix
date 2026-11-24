;;; goonix: CA-3 compiler-produced self references and resolved fallback.
(use-modules (guix)
             (guix tests)
             (guix ca)
             (gnu packages bootstrap)
             (guix derivations)
             (ice-9 binary-ports)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1)
             (srfi srfi-34)
             (srfi srfi-64))

(test-begin "ca-compiler")
(define store (open-connection-for-tests))
(%graft? #f)

(define (bytevector-contains? haystack needle)
  (let ((size (bytevector-length needle)))
    (let loop ((offset 0))
      (and (<= (+ offset size) (bytevector-length haystack))
           (or (let loop ((index 0))
                 (or (= index size)
                     (and (= (bytevector-u8-ref haystack (+ offset index))
                             (bytevector-u8-ref needle index))
                          (loop (+ index 1)))))
               (loop (+ offset 1)))))))

(define compiler-drv (package-derivation store %bootstrap-gcc))
(define binutils-drv (package-derivation store %bootstrap-binutils))
(define libc-drv (package-derivation store %bootstrap-glibc))
(define guile-drv (package-derivation store %bootstrap-guile))
(define guile (string-append (derivation->output-path guile-drv) "/bin/guile"))
(define module-path (string-append (derivation->output-path guile-drv)
                                   "/share/guile/2.0"))
(define mkdir (add-to-store store "mkdir" #t "sha256"
                            (search-bootstrap-binary "mkdir" (%current-system))))
(define bash (add-to-store store "bash" #t "sha256"
                           (search-bootstrap-binary "bash" (%current-system))))

(define c-source
  "#include <stdlib.h>\n#include <string.h>\n#include <stdint.h>\n#ifndef DIRECTORY\n#error DIRECTORY is required\n#endif\nstatic const char directory[] = DIRECTORY;\nstatic inline uint64_t load(const char *p) {\n uint64_t value; memcpy(&value, p, sizeof(value)); return value; }\nint main(void) {\n const char *path = getenv(\"out\");\n if (!path || strlen(path) < sizeof(directory) - 1 + 32) return 2;\n if (memcmp(path, directory, sizeof(directory) - 1) != 0) return 1;\n path += sizeof(directory) - 1;\n if (load(path + 0) != C0) return 1;\n if (load(path + 8) != C1) return 1;\n if (load(path + 16) != C2) return 1;\n if (load(path + 24) != C3) return 1;\n return 0;\n}\n")

(define (compile-prefix-derivation name addressing)
  (let* ((gcc (derivation->output-path compiler-drv))
         (binutils (derivation->output-path binutils-drv))
         (libc (derivation->output-path libc-drv))
         (builder
          `(begin
             (use-modules (rnrs io ports) (rnrs bytevectors)
                          (ice-9 binary-ports) (ice-9 format))
             (define out (getenv "out"))
             (define slash
               (let loop ((i (- (string-length out) 1)))
                 (if (char=? (string-ref out i) #\/)
                     i
                     (loop (- i 1)))))
             (define base (substring out (+ slash 1)))
             (define dash
               (let loop ((i 0))
                 (if (char=? (string-ref base i) #\-) i (loop (+ i 1)))))
             (define hash (substring base 0 dash))
             (define directory (string-append (substring out 0 (+ slash 1))))
             (define (chunk-integer text offset)
               (let loop ((index 0) (value 0))
                 (if (= index 8)
                     value
                     (loop (+ index 1)
                           (+ value
                              (ash (char->integer
                                    (string-ref text (+ offset index)))
                                   (* 8 index)))))))
             (define (contains? bytes text)
               (let ((needle (string->utf8 text))
                     (n (string-length text)))
                 (let loop ((i 0))
                   (and (<= (+ i n) (bytevector-length bytes))
                        (or (let loop ((j 0))
                              (or (= j n)
                                  (and (= (bytevector-u8-ref bytes (+ i j))
                                          (bytevector-u8-ref needle j))
                                       (loop (+ j 1)))))
                            (loop (+ i 1)))))))
             (call-with-output-file "prefix.c"
               (lambda (port) (display ,c-source port)))
             (setenv "PATH" ,(string-append binutils "/bin"))
             (setenv "LC_ALL" "C")
             (unless (zero?
                      (apply system* ,(string-append gcc "/bin/.gcc-wrapped")
                             ,(string-append "-B" binutils "/bin")
                             ,(string-append "-B" libc "/lib")
                             ,(string-append "-L" libc "/lib")
                             ,(string-append "-Wl,-rpath," libc "/lib")
                             ,(string-append "-Wl,-dynamic-linker," libc
                                             "/lib/ld-linux-x86-64.so.2")
                             ,(string-append "-I" libc "/include")
                             "-O2" "-fno-ident" "-fno-asynchronous-unwind-tables"
                             (string-append "-DDIRECTORY=\"" directory "\"")
                             (append
                              (map (lambda (index offset)
                                     (format #f "-DC~a=0x~xULL" index
                                             (chunk-integer hash offset)))
                                   '(0 1 2 3) '(0 8 16 24))
                              '("prefix.c" "-o" "prefix"))))
               (error "compiler failed"))
             (let ((port (open-file-input-port "prefix")))
               (let ((bytes (get-bytevector-all port)))
                 (close-port port)
                 (when (contains? bytes hash)
                   (error "complete output hash remained in compiler output"))
                 (unless (contains? bytes (substring hash 0 8))
                   (error "compiler did not emit a split output hash"))))
             (unless (zero? (system* "./prefix"))
               (error "compiled prefix predicate failed"))
             (unless (zero? (system* ,mkdir "-p" (string-append out "/bin")))
               (error "mkdir failed"))
             (copy-file "prefix" (string-append out "/bin/prefix"))
             (chmod (string-append out "/bin/prefix") #o555))))
    (derivation store name guile
                '("--no-auto-compile" "$NIX_BUILD_TOP/builder.scm")
                #:inputs (list (list guile-drv) (list compiler-drv)
                               (list binutils-drv) (list libc-drv))
                #:sources (list mkdir bash)
                #:addressing addressing
                #:env-vars
                `(("GUILE_LOAD_PATH" . ,module-path)
                  ("__files" . "builder.scm")
                  ("__file:builder.scm" . ,(object->string builder))))))

(test-group "CA-3 compiler-produced split token"
  (test-equal "optimized C output is refused when its token is split by GCC"
    "opaque self-reference fragment"
    (let ((log (open-output-string)))
      (guard (condition ((store-protocol-error? condition) #t))
        (parameterize ((current-build-output-port log))
          (build-derivations store
                             (list (compile-prefix-derivation
                                    "ca-compiled-prefix" 'content))))
        #f)
      (and (string-contains (get-output-string log)
                            "opaque self-reference fragment")
           "opaque self-reference fragment")))
  (test-assert "the same compiler recipe uses resolved addressing"
    (let ((drv (compile-prefix-derivation "ca-compiled-prefix-opaque" 'resolved)))
      (build-derivations store (list drv))
      (let* ((path (realised-output-path store drv "out"))
             (binary (string-append path "/bin/prefix"))
             (base (basename path))
             (hash (substring base 0 (string-index base #\-)))
             (bytes (call-with-input-file binary get-bytevector-all
                                          #:binary #t)))
        (and (direct-store-path? path)
             (not (placeholder-path? path))
             (file-exists? binary)
             (not (bytevector-contains? bytes (string->utf8 hash)))
             (bytevector-contains? bytes (string->utf8 (substring hash 0 8))))))))

(test-group "CA-3 resolved glibc and dependent"
  (test-assert "bootstrap glibc builds resolved-addressed and its dependent resolves"
    (let* ((original (package-derivation store %bootstrap-glibc))
           (selected
            (derivation store (derivation-name original)
                        (derivation-builder original)
                        (derivation-builder-arguments original)
                        #:system (derivation-system original)
                        #:inputs (derivation-inputs original)
                        #:sources (derivation-sources original)
                        #:env-vars (derivation-builder-environment-vars original)
                        #:outputs (derivation-output-names original)
                        #:addressing 'resolved)))
      (build-derivations store (list selected))
      (let* ((glibc (realised-output-path store selected "out"))
             (placeholder (derivation->output-path selected))
             (builder
              "(define out (getenv \"out\"))\n(call-with-output-file out (lambda (p) (display (getenv \"glibc\") p)))")
             (builder-file (add-text-to-store store "glibc-dependent-builder"
                                              builder))
             (dependent
              (derivation store "ca-glibc-dependent" guile
                          (list "--no-auto-compile" builder-file)
                          #:inputs (list (list guile-drv) (list selected))
                          #:sources (list builder-file)
                          #:env-vars `(("glibc" . ,placeholder))
                          #:addressing 'content)))
        (build-derivations store (list dependent))
        (let ((result (realised-output-path store dependent "out")))
          (and (placeholder-path? placeholder)
               (not (string=? placeholder glibc))
               (valid-path? store glibc)
               (not (placeholder-path? glibc))
               (string=? glibc (call-with-input-file result get-string-all))
               (member glibc (references store result))))))))

(test-end "ca-compiler")

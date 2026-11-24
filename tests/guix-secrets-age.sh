#!/bin/sh
# goonix: stock age interoperability and authenticated-failure gates.
set -eu
if ! command -v age >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
    echo 'stock age tools are missing; install the flake development shell with age' >&2
    exit 77
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
export GOONIX_AGE_WORK="$work"
./pre-inst-env guile --no-auto-compile -c '
(use-modules (guix secrets age) (rnrs bytevectors) (ice-9 textual-ports))
(define work (getenv "GOONIX_AGE_WORK"))
(define identity (generate-x25519-identity))
(call-with-output-file (string-append work "/identity")
  (lambda (p) (display identity p)))
(call-with-output-file (string-append work "/ours.age")
  (lambda (p) (display (encrypt-x25519 (string->utf8 "stock age round trip\n")
                                     (list (x25519-identity-public identity))) p)))
'
age -r "$(age-keygen -y "$work/identity")" -a -o "$work/stock.age" <<'EOF'
from stock age
EOF
test "$(age -d -i "$work/identity" "$work/ours.age")" = 'stock age round trip'
./pre-inst-env guile --no-auto-compile -c '
(use-modules (guix secrets age) (rnrs bytevectors) (ice-9 textual-ports))
(define work (getenv "GOONIX_AGE_WORK"))
(define identity (call-with-input-file (string-append work "/identity") get-string-all))
(define ciphertext (call-with-input-file (string-append work "/stock.age") get-string-all))
(unless (equal? (string->utf8 "from stock age\n") (decrypt-age-file ciphertext (list identity)))
  (error "stock age plaintext differs"))
(define ours (call-with-input-file (string-append work "/ours.age") get-string-all))
(define wrong (generate-x25519-identity))
(define (must-refuse name thunk)
  (when (false-if-exception (begin (thunk) #t)) (error name "was accepted")))
(must-refuse "wrong identity" (lambda () (decrypt-age-file ours (list wrong))))
(must-refuse "truncated file" (lambda () (decrypt-age-file (substring ours 0 100) (list identity))))
(let ((index (string-index ours #\A 50))
      (chars (string->list ours)))
  (list-set! chars index (if (char=? (list-ref chars index) #\A) #\B #\A))
  (must-refuse "flipped ciphertext bit"
               (lambda () (decrypt-age-file (list->string chars) (list identity)))))
'
echo 'stock age interoperability and corruption refusal: PASS'

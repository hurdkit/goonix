#!/bin/sh
# goonix: SSH Ed25519 recipients, judged by stock age (no published SSH vectors).
set -eu
if ! command -v age >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
    echo 'stock age tools are missing; install the flake development shell with age' >&2
    exit 77
fi
if ! command -v ssh-keygen >/dev/null 2>&1; then
    echo 'ssh-keygen is missing; install the flake development shell with OpenSSH' >&2
    exit 77
fi
work=$(mktemp -d)
trap 'if test "${GOONIX_SSH_KEEP:-}" = keep; then echo "retained SSH fixture: $work" >&2; else rm -rf "$work"; fi' EXIT HUP INT TERM
ssh-keygen -q -t ed25519 -N '' -f "$work/key"
ssh-keygen -q -t ed25519 -N '' -f "$work/wrong"
export GOONIX_SSH_WORK="$work"
./pre-inst-env guile --no-auto-compile -c '
(use-modules (guix secrets age) (rnrs bytevectors) (ice-9 textual-ports))
(define work (getenv "GOONIX_SSH_WORK"))
(define public (call-with-input-file (string-append work "/key.pub") get-string-all))
(call-with-output-file (string-append work "/ours.age")
 (lambda (p) (display (encrypt-age (string->utf8 "SSH recipient round trip\n") (list public)) p)))
'
age -r "$(cat "$work/key.pub")" -a -o "$work/stock.age" <<'EOF'
from stock age with SSH
EOF
test "$(age -d -i "$work/key" "$work/ours.age")" = 'SSH recipient round trip'
./pre-inst-env guile --no-auto-compile -c '
(use-modules (guix secrets age) (rnrs bytevectors) (ice-9 textual-ports))
(define work (getenv "GOONIX_SSH_WORK"))
(define identity (read-ssh-identity (string-append work "/key")))
(define wrong (read-ssh-identity (string-append work "/wrong")))
(define stock (call-with-input-file (string-append work "/stock.age") get-string-all))
(unless (equal? (string->utf8 "from stock age with SSH\n")
                (decrypt-age-file stock (list identity)))
  (error "stock age SSH plaintext differs"))
(define ours (call-with-input-file (string-append work "/ours.age") get-string-all))
(when (false-if-exception (decrypt-age-file ours (list wrong)))
  (error "wrong SSH key was accepted"))
(define stanzas (age-header-stanzas ours))
(define changed (map (lambda (s) (if (string=? (car s) "ssh-ed25519")
                                    (list (car s) (cons "AAAA" (cdadr s)) (caddr s)) s)) stanzas))
(when (false-if-exception (unwrap-ssh-stanza identity (car changed)))
  (error "mismatched SSH stanza tag was accepted"))
'
echo 'SSH age interoperability and wrong-key/tag refusal: PASS'

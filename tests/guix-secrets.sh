#!/bin/sh
# goonix: vault command behavior, plaintext confinement and recipient changes.
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir "$work/home" "$work/tmp" "$work/vault" "$work/out" "$work/store"
export HOME=$work/home TMPDIR=$work/tmp GUIX_SECRETS_IDENTITY=$work/identity
export GUIX_SECRETS_VAULT=$work/vault
export GUIX_SECRETS_LOCAL_OPTIONS_DIRECTORY=$work
export GUIX_SECRETS_TEST_TMPDIR=$work/tmp
canary='goonix-vault-canary-7bd90d8f0b-private'
new_canary='goonix-vault-canary-rekeyed-private'
export GOONIX_CANARY=$canary

# The harness owns this isolated store-like tree; vault commands never use a daemon.
check_canary() {
  if grep -R -F -l "$canary" "$work/vault" "$work/store" "$work/tmp" >/dev/null 2>&1; then
    echo 'plaintext canary survived in a vault, store item or temporary file' >&2
    exit 1
  fi
  if find "$work/tmp" -mindepth 1 -maxdepth 1 -name 'guix-secrets*' -print -quit | grep -q .; then
    echo 'a secrets temporary directory survived' >&2
    exit 1
  fi
  if test -e "$work/identity" && grep -F -l "$canary" "$work/identity" >/dev/null 2>&1; then
    echo 'plaintext canary reached the identity' >&2; exit 1
  fi
}
run() {
  "$@"
  check_canary
}

run ./pre-inst-env guix secrets init
recipient=$(sed -n 's/.*(owner "\([^"]*\)").*/\1/p' "$work/vault/vault.scm")
test -n "$recipient"
cat > "$work/vault/vault.scm" <<EOF
(vault (format 1) (recipients (owner "$recipient"))
 (secrets (value (kind file) (for owner))
          (generated (kind password) (for owner))
          (guest (kind ssh-key) (for owner))))
EOF
cat > "$work/editor" <<'EOF'
#!/bin/sh
printf %s "$GOONIX_CANARY" > "$1"
EOF
chmod 755 "$work/editor"
export VISUAL=$work/editor
run ./pre-inst-env guix secrets add value
run ./pre-inst-env guix secrets show value > "$work/out/shown"
test "$(cat "$work/out/shown")" = "$canary"
run ./pre-inst-env guix secrets list > "$work/out/list"
grep -Fx value "$work/out/list"
grep -Fx generated "$work/out/list"
run ./pre-inst-env guix secrets generate password generated
run ./pre-inst-env guix secrets generate --local -d "$work/vault" ssh-key guest
test -s "$work/vault/guest.pub"
grep -F 'guest-public-key' "$work/flake.local.scm"
run ./pre-inst-env guix secrets check

# The encrypted vault may enter the store.  Build one real store item from
# only its ciphertext and declaration; no identity is available to the build.
store_item=$(GOONIX_STORE_SOURCE=$work/vault ./test-env ./pre-inst-env guile --no-auto-compile -c '
(use-modules (guix store))
(define store (open-connection))
(display (add-to-store store "goonix-secrets-vault" #t "sha256"
                       (getenv "GOONIX_STORE_SOURCE")))
(close-connection store)')
test -d "$store_item"
if grep -R -F -l "$canary" "$store_item" >/dev/null 2>&1; then
  echo 'plaintext canary is in the real store item' >&2; exit 1
fi
cp "$store_item/value.age" "$work/store/value.age"
check_canary

# The generated private half exists only encrypted in the vault.  OpenSSH and
# stock age independently validate the pair and the resulting SSH recipient.
./pre-inst-env guile --no-auto-compile -c '
(use-modules (guix secrets vault) (guix secrets age) (rnrs bytevectors) (ice-9 textual-ports))
(define id (read-identity (getenv "GUIX_SECRETS_IDENTITY")))
(define vault (call-with-input-file (string-append (getenv "GUIX_SECRETS_VAULT") "/vault.scm") read-vault))
(define key (utf8->string (show-secret (getenv "GUIX_SECRETS_VAULT") vault (quote guest) id)))
(call-with-output-file (string-append (getenv "HOME") "/guest-openssh")
  (lambda (p) (display key p)))'
chmod 600 "$work/home/guest-openssh"
ssh-keygen -y -f "$work/home/guest-openssh" | cut -d' ' -f1,2 > "$work/out/derived.pub"
cut -d' ' -f1,2 "$work/vault/guest.pub" > "$work/out/public.pub"
cmp "$work/out/derived.pub" "$work/out/public.pub"
printf 'SSH vault interoperability\n' > "$work/out/plain"
age -r "$(cat "$work/vault/guest.pub")" -o "$work/out/ssh.age" "$work/out/plain"
age -d -i "$work/home/guest-openssh" "$work/out/ssh.age" > "$work/out/ssh.out"
cmp "$work/out/plain" "$work/out/ssh.out"
rm "$work/home/guest-openssh"

# A stock-age scrypt identity is readable; no plaintext identity is tracked.
cp tests/fixtures/age-identity.scrypt "$work/home/identity.age"
GOONIX_ENCRYPTED_IDENTITY=$work/home/identity.age ./pre-inst-env guile --no-auto-compile -c '
(use-modules (guix secrets vault) (guix secrets age))
(define (read-it pass) (read-identity-with-passphrase
                         (getenv "GOONIX_ENCRYPTED_IDENTITY") (lambda (_) pass)))
(unless (string=? "age1e2usjplzlhfsq5hgsc8a9drrfcqsc2hwdwevrn0hju522ky94uyqaugnrn"
                  (x25519-identity-public (read-it "age")))
  (error "stock age scrypt identity was not read"))
(when (false-if-exception (read-it "wrong passphrase"))
  (error "wrong encrypted identity passphrase was accepted"))'
GUIX_SECRETS_IDENTITY=$work/identity run ./pre-inst-env guix secrets check

# Decrypt is explicit and may only create an output outside the vault/store.
run ./pre-inst-env guix secrets decrypt value -o "$work/out/decrypted"
test "$(cat "$work/out/decrypted")" = "$canary"
rm "$work/out/decrypted"
if ./pre-inst-env guix secrets decrypt value -o "$work/vault/leak" 2>/dev/null; then
  echo 'decrypt into the vault succeeded' >&2; exit 1
fi
check_canary

# Success and ordinary failure both remove the materialisation directory.
run ./pre-inst-env guix secrets exec -- sh -c 'test "$(cat "$GUIX_SECRETS_DIRECTORY/value")" = "$GOONIX_CANARY"; printf %s "$GUIX_SECRETS_DIRECTORY" > "$1"' sh "$work/out/exec-path"
test ! -e "$(cat "$work/out/exec-path")"
if ./pre-inst-env guix secrets exec -- sh -c 'printf %s "$GUIX_SECRETS_DIRECTORY" > "$1"; exit 19' sh "$work/out/fail-path"; then
  echo 'failing exec returned success' >&2; exit 1
fi
check_canary
test ! -e "$(cat "$work/out/fail-path")"

# A signal delivered to the command's process group must not strand plaintext.
cat > "$work/sleeper" <<'EOF'
#!/bin/sh
printf %s "$GUIX_SECRETS_DIRECTORY" > "$1"
sleep 30
EOF
chmod 755 "$work/sleeper"
./pre-inst-env guix secrets exec -- "$work/sleeper" "$work/out/killed-path" >"$work/out/killed.log" 2>&1 &
pid=$!
for i in $(seq 1 100); do test -s "$work/out/killed-path" && break; sleep .05; done
test -s "$work/out/killed-path"
kill -TERM "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
check_canary
test ! -e "$(cat "$work/out/killed-path")"

# Replace the declaration with a new recipient before rekey.  The old identity
# must open no file afterwards; the new identity opens every file.
new_id=$work/new-identity
# Use the command's generator-independent library only to create fixture data.
GOONIX_NEW_IDENTITY=$new_id ./pre-inst-env guile --no-auto-compile -c '
(use-modules (guix secrets age))
(call-with-output-file (getenv "GOONIX_NEW_IDENTITY")
 (lambda (p) (format p "~a~%" (generate-x25519-identity))))'
new_recipient=$(GOONIX_NEW_IDENTITY=$new_id ./pre-inst-env guile --no-auto-compile -c '
(use-modules (guix secrets age) (ice-9 textual-ports))
(display (x25519-identity-public (call-with-input-file (getenv "GOONIX_NEW_IDENTITY") get-string-all)))')
cat > "$work/vault/vault.scm" <<EOF
(vault (format 1) (recipients (new "$new_recipient"))
 (secrets (value (kind file) (for new))
          (generated (kind password) (for new))
          (guest (kind ssh-key) (for new))))
EOF
run ./pre-inst-env guix secrets rekey
for name in value generated guest; do
  if ./pre-inst-env guix secrets show "$name" > "$work/out/old-$name" 2>/dev/null; then
    echo "removed recipient still opens rekeyed $name" >&2; exit 1
  fi
done
check_canary
GUIX_SECRETS_IDENTITY=$new_id run ./pre-inst-env guix secrets show value > "$work/out/new"
test "$(cat "$work/out/new")" = "$canary"
GUIX_SECRETS_IDENTITY=$new_id run ./pre-inst-env guix secrets check

# Both the explicitly selected local vault and its default location collide
# with a shared declaration of the same name.
mkdir "$work/local-explicit" "$work/state"
cp "$work/vault/vault.scm" "$work/local-explicit/vault.scm"
if GUIX_SECRETS_LOCAL_VAULT=$work/local-explicit ./pre-inst-env guix secrets list >"$work/out/collision" 2>&1; then
  echo 'explicit local/shared name collision was accepted' >&2; exit 1
fi
grep -F 'both shared and local vaults' "$work/out/collision"
mkdir -p "$work/state/guix/secrets-local"
cp "$work/vault/vault.scm" "$work/state/guix/secrets-local/vault.scm"
if XDG_STATE_HOME=$work/state ./pre-inst-env guix secrets list >"$work/out/default-collision" 2>&1; then
  echo 'default local/shared name collision was accepted' >&2; exit 1
fi
grep -F 'both shared and local vaults' "$work/out/default-collision"
check_canary

printf 'guix secrets vault behavior: PASS\n'

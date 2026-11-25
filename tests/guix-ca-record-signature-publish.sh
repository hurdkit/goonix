#!/usr/bin/env bash
# goonix: a pre-base64 record must be normalised when the daemon loads it.
# The fixture is signed by the real daemon, then its raw high-byte form is
# inserted in an isolated test database.  Only guix publish is under test.
set -euo pipefail
if ! unshare --user --map-root-user --mount true 2>/dev/null; then
  printf 'SKIP: user/mount namespaces are unavailable\n'
  exit 77
fi
root=$(mktemp -d "${GOONIX_SIGNATURE_TMPDIR:-${TMPDIR:-/tmp}}/goonix-signature-publish-XXXXXX")
echo "SIGNATURE_FIXTURE=$root"
store=$root/store
port=${GOONIX_SIGNATURE_PORT:-6798}
url=http://127.0.0.1:$port
mkdir -p "$store" "$root/db" "$root/etc" "$root/log"
cp tests/keys/openpgp/signing-key.sec tests/keys/openpgp/signing-key.pub "$root/etc/"
chmod 400 "$root/etc/signing-key.sec"
printf '#!/bin/sh\nexec /bin/sh "$@"\n' > "$root/shell"
chmod 755 "$root/shell"
export GOONIX_SHELL_SOURCE=$root/shell GOONIX_LEGACY_FIXTURE=$root/fixture.scm
export GUILE_AUTO_COMPILE=0
export NIX_STORE_DIR=$store GUIX_DATABASE_DIRECTORY=$root/db
export GUIX_CONFIGURATION_DIRECTORY=$root/etc GUIX_STATE_DIRECTORY=$root
export GUIX_DAEMON_SOCKET=$root/socket GUIX_LOG_DIRECTORY=$root/log
./pre-inst-env ./guix-daemon --disable-chroot --listen="$root/socket" \
  --substitute-urls= >"$root/server.log" 2>&1 & daemon=$!
trap 'kill "$daemon" 2>/dev/null || true; wait 2>/dev/null || true' EXIT
for i in $(seq 1 100); do test -S "$root/socket" && break; sleep .1; done
# Obtain a real C++-signed high-byte signature, then decode and verify it in
# Scheme.  Run this in the same prepared environment as the daemon, so gcrypt
# and guix authenticate are both available.
printf '#!/bin/sh\nexec %s guix "$@"\n' "$PWD/pre-inst-env" > "$root/guix-helper"
chmod +x "$root/guix-helper"
GUIX_CONFIGURATION_DIRECTORY=$root/etc ./pre-inst-env ./nix/records-test \
  --sign-high-byte "$root/signing" "$root/guix-helper" "$root/cpp-signature"
export GOONIX_CPP_SIGNATURE=$root/cpp-signature
./pre-inst-env guile --no-auto-compile tests/ca-record-signature-cpp-client.scm
./pre-inst-env guile --no-auto-compile tests/ca-record-signature-publish-fixture.scm
sqlite3 "$root/db/db.sqlite" '.timeout 10000' 'PRAGMA wal_checkpoint(FULL);'
./pre-inst-env guix publish --listen=127.0.0.1 --port="$port" -C0 \
  >"$root/publish.log" 2>&1 & publish=$!
trap 'kill "$publish" "$daemon" 2>/dev/null || true; wait 2>/dev/null || true' EXIT
ready=false
for i in $(seq 1 100); do
  if curl -fsS "$url/nix-cache-info" >/dev/null 2>&1; then ready=true; break; fi
  sleep .1
done
$ready
kill -0 "$publish"
drv=$(basename "$(sed -n 's/.*(derivation "\([^"]*\)").*/\1/p' "$root/fixture.scm")")
request() {
  curl -sS -o "$root/response" -w '%{http_code}' "$url/goonix/records/$drv"
}
code=$(request)
test "$code" = 200
raw=$(sqlite3 "$root/db/db.sqlite" '.timeout 10000' \
  "SELECT hex(signature) FROM GoonixBuildRecords
   WHERE path = '$(sed -n 's/.*(output "\([^"]*\)").*/\1/p' "$root/fixture.scm")';")
export GOONIX_RESPONSE=$root/response
export GOONIX_EXPECTED_HEX=$(printf '%s' "$raw" | tr A-F a-f)
./pre-inst-env guile --no-auto-compile tests/ca-record-signature-publish-client.scm

# The exact legacy failure shape: raw high bytes in a quoted S-expression.
sqlite3 "$root/db/db.sqlite" '.timeout 10000' \
 "UPDATE GoonixBuildRecords SET signature = x'287369676e6174757265200a2028640a202028706b637331290a20202868617368207368613235362022587748314b59a5245c62366f4225b8'
  WHERE path = '$(sed -n 's/.*(output "\([^"]*\)").*/\1/p' "$root/fixture.scm")';"
code=$(request)
test "$code" = 200
cp "$root/response" "$root/high-byte-response"
export GOONIX_EXPECTED_HEX=287369676e6174757265200a2028640a202028706b637331290a20202868617368207368613235362022587748314b59a5245c62366f4225b8
./pre-inst-env guile --no-auto-compile tests/ca-record-signature-publish-client.scm
! grep -q 'input locale conversion error' "$root/publish.log"
test "$(curl -sS -o /dev/null -w '%{http_code}' "$url/nix-cache-info")" = 200

# An aggregate graph skips a garbage row and warns; it does not poison the
# valid-record query path or stop the publisher.  Direct verification of that
# field is tested by nix/records-test and still refuses it.
sqlite3 "$root/db/db.sqlite" '.timeout 10000' \
 "UPDATE GoonixBuildRecords SET signature = 'not base64 or a signature'
  WHERE path = '$(sed -n 's/.*(output "\([^"]*\)").*/\1/p' "$root/fixture.scm")';"
code=$(request)
test "$code" = 200
grep -q '(goonix-records 1 (choices ()))' "$root/response"
grep -q 'ignoring invalid record signature for `' "$root/publish.log"
! grep -q 'input locale conversion error' "$root/publish.log"
test "$(curl -sS -o /dev/null -w '%{http_code}' "$url/nix-cache-info")" = 200

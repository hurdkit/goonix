#!/usr/bin/env bash
# goonix: run HS-3 archive behavior against a fresh, private store.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
fixture=${1:-${TMPDIR:-/tmp}/goonix-hs3-focused}
daemon=${GOONIX_TEST_DAEMON:-$root/guix-daemon}
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
mkdir -p "$fixture/config"
cp "$root/tests/keys/openpgp/signing-key.sec" "$fixture/config/signing-key.sec"
cp "$root/tests/keys/openpgp/signing-key.pub" "$fixture/config/signing-key.pub"
chmod 0600 "$fixture/config/signing-key.sec"
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
export GUIX_CONFIGURATION_DIRECTORY="$fixture/config" HS3_ROOT="$fixture"
export GUIX=${GUIX:-/run/current-system/sw/bin/guix}
"$daemon" --disable-chroot --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
for i in $(seq 1 200); do
  test -S "$GUIX_DAEMON_SOCKET" && break
  kill -0 "$pid"
  sleep .01
done
test -S "$GUIX_DAEMON_SOCKET"
timeout 60 "$root/pre-inst-env" guile --no-auto-compile \
  "$root/daemon/test/differential/archive-check.scm"

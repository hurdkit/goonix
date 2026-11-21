#!/usr/bin/env bash
# goonix: run Guix's daemon tests with a fresh store for every invocation.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
if test "$#" -lt 1; then
  echo "usage: fresh-store.sh TEST [ARG ...]" >&2
  exit 2
fi
fixture=${GOONIX_TEST_FIXTURE:-$root/.scratch/hs-current-fixture}
daemon=${GOONIX_TEST_DAEMON:-$root/guix-daemon}
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
mkdir -p "$fixture/etc" "$fixture/substituter-data" "$fixture/cache"
cp "$root/tests/keys/openpgp/signing-key.sec" "$fixture/etc/signing-key.sec"
cp "$root/tests/keys/openpgp/signing-key.pub" "$fixture/etc/signing-key.pub"
chmod 0400 "$fixture/etc/signing-key.sec"
export NIX_STORE_DIR="$fixture/store"
export GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var"
export GUIX_DAEMON_SOCKET="$fixture/var/socket"
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix"
export GUIX_CONFIGURATION_DIRECTORY="$fixture/etc"
export GUIX_BINARY_SUBSTITUTE_URL="file://$fixture/substituter-data"
export GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES=yes
export XDG_CACHE_HOME="$fixture/cache"
export GUIX_TEST_DAEMON_OPTIONS=--disable-chroot
export HS3_ROOT="$fixture" HS7_FIXTURE="$fixture"
if test -n "${WATCHDOG_PID:-}"; then
  trap 'test ! -e /proc/$WATCHDOG_PID || kill $WATCHDOG_PID 2>/dev/null || true' EXIT
fi
# Use a clean compiled-module path for generated bootstrap Guile programs.
unset GUILE_LOAD_COMPILED_PATH
# Extra options are for isolated test daemons, never the host daemon.
goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --allow-aslr \
  --substitute-urls="$GUIX_BINARY_SUBSTITUTE_URL" \
  ${GOONIX_DAEMON_OPTIONS:-} \
  --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1
pid=$GOONIX_TEST_PID
daemon_scope=$GOONIX_TEST_SCOPE
cleanup() {
  goonix_stop_capped "$pid" "$daemon_scope"
}
trap cleanup EXIT
for i in $(seq 1 300); do
  test -S "$GUIX_DAEMON_SOCKET" && break
  kill -0 "$pid"
  sleep .01
done
test -S "$GUIX_DAEMON_SOCKET"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$@"

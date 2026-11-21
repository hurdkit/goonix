#!/usr/bin/env bash
# A failed initial exec must match C++ client and build-log diagnostics.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${GOONIX_HS_DAEMON:-$root/guix-daemon}
fixture=${1:-$root/.scratch/missing-builder}
pid= scope=
cleanup() {
  status=$?
  trap - EXIT
  if test -n "$pid"; then goonix_stop_capped "$pid" "$scope" || status=$?; fi
  if test "$status" -eq 0; then
    chmod -R u+rwX "$fixture" 2>/dev/null || true
    rm -rf "$fixture"
  fi
  return "$status"
}
trap cleanup EXIT
if test -e "$fixture"; then chmod -R u+rwX "$fixture" 2>/dev/null || true; rm -rf "$fixture"; fi
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix" GUIX_CONFIGURATION_DIRECTORY="$fixture/etc"
export GUILE_AUTO_COMPILE=0
goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --no-substitutes --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1
pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
test -S "$GUIX_DAEMON_SOCKET"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/missing-builder.scm" >"$fixture/client.log" 2>&1 || { cat "$fixture/client.log"; exit 1; }
cat "$fixture/client.log"
grep -F 'missing-builder client status and message: PASS' "$fixture/client.log"
log=$(find "$fixture/var/log/guix" -type f -name '*-missing-builder.drv.gz' -print -quit)
test -n "$log"
gzip -t "$log"
gzip -cd "$log" >"$fixture/build.log"
grep -F 'while setting up the child process: in phase exec: getting status of `' "$fixture/build.log"
grep -F "': No such file or directory" "$fixture/build.log"
printf 'missing-builder valid build log: PASS\n'

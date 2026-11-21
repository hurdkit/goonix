#!/usr/bin/env bash
# Two clients of one daemon share the output lock, not a scheduler.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${GOONIX_HS_DAEMON:-$root/guix-daemon}
out=${1:-$root/.scratch/hs4-two-client}
mkdir -p "$out"
fixture=$(mktemp -d /tmp/goonix-two-client-XXXXXX)
pid= scope=
cleanup() {
  status=$?
  trap - EXIT
  test -e "$fixture/release-builder" || touch "$fixture/release-builder"
  exec 9>&- 2>/dev/null || true
  if test -n "$pid"; then goonix_stop_capped "$pid" "$scope"; fi
  if test "$status" -ne 0; then cp -a "$fixture" "$out/fixture"; fi
  rm -rf "$fixture"
  return "$status"
}
trap cleanup EXIT
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/s"
export HS4_SCHEDULER_FIXTURE="$fixture" GUILE_AUTO_COMPILE=0
mkdir -p "$NIX_STORE_DIR" "$GUIX_DATABASE_DIRECTORY" "$GUIX_STATE_DIRECTORY"
mkfifo "$fixture/tick"
exec 9<>"$fixture/tick"
goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --no-substitutes --listen="$GUIX_DAEMON_SOCKET" >"$out/daemon.log" 2>&1
pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
test -S "$GUIX_DAEMON_SOCKET"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/two-client-build.scm" >"$out/client.log" 2>&1
cat "$out/client.log"

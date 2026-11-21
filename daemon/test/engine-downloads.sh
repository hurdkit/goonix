#!/usr/bin/env bash
# Real download/build event ordering in default and opt-in modes.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
. "$root/daemon/test/lib.sh"
fixture=${1:-$root/.scratch/hs4-engine-downloads}
daemon=${GOONIX_HS_DAEMON:-$root/guix-daemon}
export GOONIX_TEST_TIMEOUT=${GOONIX_TEST_TIMEOUT:-120}
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix" GUIX_CONFIGURATION_DIRECTORY="$fixture/etc"
export GUILE_AUTO_COMPILE=0 HS4_SCHEDULER_FIXTURE="$fixture"
export GUIX_BINARY_SUBSTITUTE_URL="file://$fixture/substituter-data"
export GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES=yes
export XDG_CACHE_HOME="$fixture/cache"
pid= scope=
cleanup() {
  status=$?
  trap - EXIT
  test -e "$fixture/release-builder-default" || touch "$fixture/release-builder-default"
  test -e "$fixture/release-builder-separate" || touch "$fixture/release-builder-separate"
  exec 9>&- 2>/dev/null || true
  if test -n "$pid"; then goonix_stop_capped "$pid" "$scope"; fi
  return "$status"
}
trap cleanup EXIT
if test -e "$fixture"; then chmod -R u+rwX "$fixture" 2>/dev/null || true; rm -rf "$fixture"; fi
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
mkdir -p "$fixture/substituter-data" "$fixture/cache"
mkfifo "$fixture/tick"
exec 9<>"$fixture/tick"
goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --substitute-urls="$GUIX_BINARY_SUBSTITUTE_URL" --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1
pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
test -S "$GUIX_DAEMON_SOCKET"
for mode in default separate; do
  export HS4_DOWNLOAD_MODE=$mode
  goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/engine-downloads.scm" >"$fixture/$mode.log" 2>&1
  cat "$fixture/$mode.log"
done

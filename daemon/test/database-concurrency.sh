#!/usr/bin/env bash
# Direct regression for prepared statements shared by concurrent job threads.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${GOONIX_HS_DAEMON:-$root/guix-daemon}
fixture=${1:-$root/.scratch/hs6-database-concurrency}
socket_dir=$(mktemp -d /tmp/goonix-db-XXXXXX)
if test -e "$fixture"; then chmod -R u+rwX "$fixture"; rm -rf "$fixture"; fi
mkdir -p "$fixture"
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$socket_dir/s"
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix" GUIX_CONFIGURATION_DIRECTORY="$fixture/etc"
export GUILE_AUTO_COMPILE=0 GOONIX_TEST_TIMEOUT=${GOONIX_TEST_TIMEOUT:-180}
pid= scope=
cleanup() {
  status=$?
  trap - EXIT
  if test -n "$pid"; then goonix_stop_capped "$pid" "$scope" || status=$?; fi
  rm -rf "$socket_dir"
  if test "$status" -eq 0; then
    chmod -R u+rwX "$fixture" 2>/dev/null || true
    rm -rf "$fixture"
  fi
  return "$status"
}
trap cleanup EXIT
goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --no-substitutes --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1
pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
test -S "$GUIX_DAEMON_SOCKET"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile \
  "$root/daemon/test/database-concurrency.scm" >"$fixture/client.log" 2>&1 || {
    cat "$fixture/client.log"; exit 1;
  }
cat "$fixture/client.log"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile \
  "$root/daemon/test/database-jobs.scm" >"$fixture/jobs.log" 2>&1 || {
    cat "$fixture/jobs.log"; exit 1;
  }
cat "$fixture/jobs.log"
kill -0 "$pid"

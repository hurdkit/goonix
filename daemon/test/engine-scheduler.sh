#!/usr/bin/env bash
# Real engine concurrency: no elapsed-time success assertion.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
. "$root/daemon/test/lib.sh"
fixture=${1:-$root/.scratch/hs4-engine-scheduler}
daemon=${GOONIX_HS_DAEMON:-$root/guix-daemon}
export GOONIX_TEST_TIMEOUT=${GOONIX_TEST_TIMEOUT:-90}
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix" GUIX_CONFIGURATION_DIRECTORY="$fixture/etc"
export GUILE_AUTO_COMPILE=0 HS4_SCHEDULER_FIXTURE="$fixture"
pid= scope= tick_writer=
cleanup() {
  test -z "$tick_writer" || exec 9>&-
  if test -n "$pid"; then goonix_stop_capped "$pid" "$scope"; fi
}
trap cleanup EXIT
run_mode() {
  mode=$1
  if test -e "$fixture"; then chmod -R u+rwX "$fixture" 2>/dev/null || true; rm -rf "$fixture"; fi
  "$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
  rm -f "$fixture/tick"
  mkfifo "$fixture/tick"
  exec 9<>"$fixture/tick"
  tick_writer=1
  goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --no-substitutes --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1
  pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
  for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
  test -S "$GUIX_DAEMON_SOCKET"
  goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/seed-restore.scm" >"$fixture/seed.log" 2>&1
  HS4_SCHEDULER_MODE=$mode goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/engine-scheduler.scm" >"$fixture/client.log" 2>&1
  grep -F "HS-4 $mode independent builders: PASS" "$fixture/client.log"
  if test "$mode" = serial; then
    order=$(cat "$fixture/events")
    case "$order" in
      $'left\nleft-end\nright\nright-end'|$'right\nright-end\nleft\nleft-end') ;;
      *) printf 'serial builder intervals overlap: %s\n' "$order" >&2; exit 1;;
    esac
  fi
  exec 9>&-
  tick_writer=
  goonix_stop_capped "$pid" "$scope"
  pid= scope=
}
run_mode parallel
run_mode serial

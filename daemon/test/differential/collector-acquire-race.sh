#!/usr/bin/env bash
# Collector acquire-ordering deadlock (reviewer follow-up to 3ad3c1caf78).
#
# withCollectorGCLock must acquire the exclusive GC lock AND set the own-collector
# flag in ONE step under tempRootLock.  If it takes the lock and only then sets
# the flag, a new client arriving in between sees the flag unset, takes
# tempRootLock, and blocks in withGCReadLock on the collector's exclusive lock —
# while holding tempRootLock.  The collector's release then waits for
# tempRootLock: deadlock.
#
# The test-only GOONIX_TEST_COLLECTOR_FLAG_DELAY_US hook widens the acquire ->
# flag-set window.  A collection runs with it; a new client arrives during the
# delay and roots an item.  With the fix both finish (the client waits for
# tempRootLock, then skips the GC lock once the flag is set) and the root
# survives.  On 3ad3c1caf78 (acquire and flag-set separate, outside tempRootLock)
# this hangs and hits the timeout.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${1:?Haskell daemon required}
out=${2:-$root/.scratch/collector-acquire-race}
mkdir -p "$out"
find "$out" -mindepth 1 -maxdepth 1 -exec chmod -R u+rwX {} + 2>/dev/null || true
find "$out" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
out=$(CDPATH= cd -- "$out" && pwd)
fixture=$(mktemp -d /tmp/goonix-col-acq-XXXXXX)
socket=$fixture/s
daemon_pid= daemon_scope= probe_pid= probe_scope=
cleanup() {
  status=$?
  trap - EXIT
  if test -n "$probe_pid"; then goonix_stop_capped "$probe_pid" "$probe_scope" || status=$?; fi
  if test -n "$daemon_pid"; then goonix_stop_capped "$daemon_pid" "$daemon_scope" || status=$?; fi
  if test "$status" -ne 0; then cp -a "$fixture" "$out/fixture"; fi
  rm -rf "$fixture"
  if test "$status" -eq 0; then
    chmod -R u+rwX "$out" 2>/dev/null || true
    rm -rf "$out"
  fi
  return "$status"
}
trap cleanup EXIT
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUILE_AUTO_COMPILE=0
export COL_FIXTURE="$fixture" COL_SOCKET="$socket"
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix"
# Widen the collector's acquire -> flag-set window to 1 s so a new client
# reliably arrives inside it.
export GOONIX_TEST_COLLECTOR_FLAG_DELAY_US=1000000
unset GUIX
mkdir -p "$NIX_STORE_DIR" "$GUIX_DATABASE_DIRECTORY" "$GUIX_STATE_DIRECTORY"
goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --no-substitutes --listen="$socket" >"$out/daemon.log" 2>&1
daemon_pid=$GOONIX_TEST_PID daemon_scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 500); do test -S "$socket" && break; kill -0 "$daemon_pid"; sleep .01; done
test -S "$socket"
kill -0 "$daemon_pid"
# The probe must finish within the timeout; on the pre-fix acquire it deadlocks.
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/differential/collector-acquire-race.scm" >"$out/probe.log" 2>&1
grep -q 'collector acquire-ordering race: PASS' "$out/probe.log"
printf 'collector acquire-ordering race: PASS\n'
cleanup
trap - EXIT
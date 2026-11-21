#!/usr/bin/env bash
# Collector release-ordering race (reviewer follow-up to e9020d578b3).
#
# A new client checks ownCollectorHolds and then creates its temporary-root
# file, both under tempRootLock.  The collector must clear the flag AND release
# the exclusive GC lock under tempRootLock too; otherwise a client can see the
# flag set, skip the shared GC lock, and create its file after this process's
# collection ends but before another process's collector takes the GC lock and
# enumerates temproots/ — deleting the item the client just rooted.
#
# The test-only GOONIX_TEST_TEMPROOT_CREATE_DELAY_US hook widens the new
# client's flag-check -> file-creation window to 200ms.  A collection runs on
# the daemon (flag set), the new client roots an item across the widened window,
# and an EXTERNAL gc.lock holder is queued on the lock.  With the fix the
# collector's release waits for tempRootLock (which the client holds across the
# window), so the client's file exists before the external holder can take the
# lock.  We assert the file exists once the collection has ended and the client
# has rooted — the ordering the fix guarantees.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${1:?Haskell daemon required}
out=${2:-$root/.scratch/collector-release-race}
mkdir -p "$out"
find "$out" -mindepth 1 -maxdepth 1 -exec chmod -R u+rwX {} + 2>/dev/null || true
find "$out" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
out=$(CDPATH= cd -- "$out" && pwd)
fixture=$(mktemp -d /tmp/goonix-col-race-XXXXXX)
socket=$fixture/s
daemon_pid= daemon_scope= probe_pid= probe_scope=
cleanup() {
  status=$?
  trap - EXIT
  if test -n "$probe_pid"; then goonix_stop_capped "$probe_pid" "$probe_scope" || status=$?; fi
  if test -n "$daemon_pid"; then goonix_stop_capped "$daemon_pid" "$daemon_scope" || status=$?; fi
  exec 9>&- 2>/dev/null || status=$?
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
# Widen the new client's flag-check -> file-creation window to 200ms so the
# ordering is stressed rather than left to a few-microsecond chance.
export GOONIX_TEST_TEMPROOT_CREATE_DELAY_US=200000
unset GUIX
mkdir -p "$NIX_STORE_DIR" "$GUIX_DATABASE_DIRECTORY" "$GUIX_STATE_DIRECTORY"
goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --no-substitutes --listen="$socket" >"$out/daemon.log" 2>&1
daemon_pid=$GOONIX_TEST_PID daemon_scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 500); do test -S "$socket" && break; kill -0 "$daemon_pid"; sleep .01; done
test -S "$socket"
kill -0 "$daemon_pid"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/differential/collector-release-race.scm" >"$out/probe.log" 2>&1
grep -q 'collector release-ordering race: PASS' "$out/probe.log"
printf 'collector release-ordering race: PASS\n'
cleanup
trap - EXIT
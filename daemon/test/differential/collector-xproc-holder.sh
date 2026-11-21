#!/usr/bin/env bash
# Collector stage cross-process guard (DECISIONS.md point 3): a new client's
# first temporary root must BLOCK while ANOTHER process holds gc.lock
# exclusively.  The shared GC lock at temporary-root-file creation is what
# guarantees no file appears after another process's collector has enumerated
# temproots/.  A new client skips that lock only for its OWN process's collector
# (which reads the STM announcements); against an external holder it must wait.
#
# This test FAILS on 7d4c16ed7c8 (which dropped the shared lock for every new
# client) and PASSES with the cross-process fix.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${1:?Haskell daemon required}
out=${2:-$root/.scratch/collector-xproc-holder}
mkdir -p "$out"
find "$out" -mindepth 1 -maxdepth 1 -exec chmod -R u+rwX {} + 2>/dev/null || true
find "$out" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
out=$(CDPATH= cd -- "$out" && pwd)
fixture=$(mktemp -d /tmp/goonix-col-xproc-XXXXXX)
socket=$fixture/s
daemon_pid= daemon_scope= holder_pid= holder_scope= client_pid= client_scope=
cleanup() {
  status=$?
  trap - EXIT
  if test -n "$client_pid"; then goonix_stop_capped "$client_pid" "$client_scope" || status=$?; fi
  if test -n "$holder_pid"; then goonix_stop_capped "$holder_pid" "$holder_scope" || status=$?; fi
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
unset GUIX
mkdir -p "$NIX_STORE_DIR" "$GUIX_DATABASE_DIRECTORY" "$GUIX_STATE_DIRECTORY"
cc -O2 -Wall -Wextra "$root/daemon/test/differential/gc-lock-holder.c" -o "$out/gc-lock-holder"
goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --no-substitutes --listen="$socket" >"$out/daemon.log" 2>&1
daemon_pid=$GOONIX_TEST_PID daemon_scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 500); do test -S "$socket" && break; kill -0 "$daemon_pid"; sleep .01; done
test -S "$socket"
kill -0 "$daemon_pid"

# An EXTERNAL process holds gc.lock exclusively (as another daemon's collector
# would).  No collection of our own is running, so ownCollectorHolds is false.
goonix_start_capped "$out/gc-lock-holder" "$fixture/var/gc.lock" >"$out/holder.log" 2>&1
holder_pid=$GOONIX_TEST_PID holder_scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 500); do grep -q held "$out/holder.log" && break; sleep .01; done
grep -q held "$out/holder.log"

# A new client opens a connection and adds its first temporary root.  Creating
# the temporary-root file must take the shared GC lock and therefore BLOCK until
# the external holder releases it.
goonix_start_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/differential/collector-xproc-holder.scm" >"$out/client.log" 2>&1
client_pid=$GOONIX_TEST_PID client_scope=$GOONIX_TEST_SCOPE
# Give the client time to reach the blocked shared-lock acquisition.
sleep 1
if ! kill -0 "$client_pid" 2>/dev/null; then
  cat "$out/client.log"
  echo 'client finished while the external GC lock was held (should have blocked)' >&2
  exit 1
fi
test ! -e "$fixture/client-rooted"
# Release the external holder; the client must now complete.
goonix_stop_capped "$holder_pid" "$holder_scope"
holder_pid= holder_scope=
for i in $(seq 1 1000); do test -e "$fixture/client-rooted" && break; kill -0 "$client_pid"; sleep .01; done
test -e "$fixture/client-rooted"
wait "$client_pid"
client_pid= client_scope=
grep -q 'external GC lock blocks new temporary root: PASS' "$out/client.log"
printf 'external GC lock blocks new temporary root: PASS\n'
cleanup
trap - EXIT
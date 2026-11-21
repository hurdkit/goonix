#!/usr/bin/env bash
# Regression: writing store items must not leak file descriptors.
# Usage: fd-leak.sh [DAEMON] [FIXTURE]
# Starts DAEMON (default the Haskell daemon under test) under a low descriptor
# limit (prlimit --nofile=64:64), writes 200 distinct items through one
# connection, builds a trivial derivation, and asserts the daemon's open fd
# count after the loop is close to its count before.  Fails on a daemon whose
# writeBytes leaks (EMFILE during the loop); passes with the bracket fix.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${1:-${GOONIX_TEST_DAEMON:-$root/guix-daemon}}
fixture=${2:-$root/.scratch/hs-fd-leak}
if test -e "$fixture"; then chmod -R u+rwX "$fixture" 2>/dev/null || true; rm -rf "$fixture"; fi
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
export HS_FD_FIXTURE="$fixture" GUIX="$root/scripts/guix"
export GUILE_AUTO_COMPILE=0
rm -f "$GUIX_DAEMON_SOCKET"
test ! -e "$GUIX_DAEMON_SOCKET"
# Low descriptor limit on the daemon only; the client keeps the normal limit.
goonix_start_capped prlimit --nofile=64:64 -- \
  "$root/pre-inst-env" "$daemon" --disable-chroot --listen="$GUIX_DAEMON_SOCKET" \
  >"$fixture/daemon.log" 2>&1
pid=$GOONIX_TEST_PID
daemon_scope=$GOONIX_TEST_SCOPE
trap 'goonix_stop_capped "$pid" "$daemon_scope"' EXIT
for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
test -S "$GUIX_DAEMON_SOCKET"
# The launcher pid is the scope/timeout wrapper; find the actual daemon process
# by its --listen socket argument (unique to this fixture).
daemon_pid=$(ps -eo pid,args | grep '[g]uix-daemon' | grep -F -- "--listen=$GUIX_DAEMON_SOCKET" | awk '{print $1}' | head -1)
test -n "$daemon_pid"
fd_count() { ls "/proc/$daemon_pid/fd" 2>/dev/null | wc -l; }
before=$(fd_count)
printf 'daemon pid=%s fd-before=%s\n' "$daemon_pid" "$before"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/differential/fd-leak.scm"
after=$(fd_count)
printf 'fd-after=%s\n' "$after"
# A flat count proves no per-write leak.  Allow a small slack for transient
# sockets/locks, but a leak adds ~200 descriptors (one per item).
delta=$((after - before))
if test "$delta" -lt 0; then delta=$((-delta)); fi
printf 'fd-delta=%s\n' "$delta"
test "$delta" -le 16
printf 'fd-leak descriptor-count: PASS (before=%s after=%s delta=%s)\n' "$before" "$after" "$delta"
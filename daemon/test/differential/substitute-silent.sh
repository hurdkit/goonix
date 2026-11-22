#!/usr/bin/env bash
# goonix: the substituter wait must not freeze the whole daemon (reviewer point 1).
#
# receiveLine waits for the helper's reply/log pipes.  If that wait is an `unsafe'
# foreign call (a blocking select()), it holds its GHC capability until it returns;
# the daemon is built -threaded -N, and the next GC needs EVERY capability to stop,
# so while one client's helper is silent every other client and every build in the
# process freezes at its next GC.  An unsafe call also cannot take an asynchronous
# exception (client disconnect, timeout).  The fix waits through the GHC IO manager
# (threadWaitReadSTM on both pipes, atomically (reply `orElse` log)), which releases
# the capability and is interruptible.
#
# This test points GUIX at a fake helper that stays SILENT for SILENT_SECONDS before
# each reply, starts the daemon with a small RTS allocation area (-A) so the GC runs
# often, and requires a second client's loop of cheap allocating queries to finish
# well before the silent helper replies.  It checks the measured elapsed time, not
# only the exit code.
#
# Usage: substitute-silent.sh [DAEMON] [FIXTURE]
#   DAEMON defaults to $GOONIX_TEST_DAEMON or ./guix-daemon.  Run it with the
#   Haskell daemon before the fix (FAILS: the busy client freezes for the whole
#   silence) and after (PASSES).  RTS_A sets the allocation area (default 1m).
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${1:-${GOONIX_TEST_DAEMON:-$root/guix-daemon}}
fixture=${2:-$root/.scratch/substitute-silent}
helper="$root/daemon/test/differential/substitute-silent-helper.sh"
chmod +x "$helper"
export SILENT_SECONDS=${SILENT_SECONDS:-8}
export BUSY_ITERATIONS=${BUSY_ITERATIONS:-400}
rts_a=${RTS_A:-1m}

if test -e "$fixture"; then chmod -R u+rwX "$fixture" 2>/dev/null || true; rm -rf "$fixture"; fi
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
mkdir -p "$fixture/cache" "$fixture/etc"

export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix" GUIX_CONFIGURATION_DIRECTORY="$fixture/etc"
export XDG_CACHE_HOME="$fixture/cache" GUILE_AUTO_COMPILE=0
# The daemon resolves the substitute helper via GUIX; set it AFTER pre-inst-env
# (which otherwise forces the real scripts/guix) by wrapping with `env'.
export GUIX_BINARY_SUBSTITUTE_URL="file://$fixture/substituter-data"
export GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES=yes

pid= scope=
cleanup() {
  status=$?
  trap - EXIT
  if test -n "$pid"; then goonix_stop_capped "$pid" "$scope"; fi
  return "$status"
}
trap cleanup EXIT

# Small allocation area (-A) so the GC runs often during the busy client's loop;
# -N keeps the threaded multi-capability runtime the daemon ships with.  The
# unsafe-select freeze shows up as the busy client waiting for a GC that cannot
# stop the capability held in select().
goonix_start_capped "$root/pre-inst-env" env GUIX="$helper" "$daemon" --disable-chroot \
  --substitute-urls="$GUIX_BINARY_SUBSTITUTE_URL" --listen="$GUIX_DAEMON_SOCKET" \
  +RTS -A"$rts_a" -N -RTS \
  >"$fixture/daemon.log" 2>&1
pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid" 2>/dev/null || break; sleep .05; done
if ! test -S "$GUIX_DAEMON_SOCKET"; then
  echo "FAIL: daemon did not start"; tail -5 "$fixture/daemon.log" >&2; exit 1
fi

# The client measures its own busy-loop elapsed time and exits non-zero if it
# froze.  The outer timeout is a safety net above the silence + budget.
export GOONIX_TEST_TIMEOUT=${GOONIX_TEST_TIMEOUT:-$(( SILENT_SECONDS * 3 + 30 ))}
set +e
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile \
  "$root/daemon/test/differential/substitute-silent.scm" >"$fixture/client.log" 2>&1
rc=$?
set -e
cat "$fixture/client.log"
if test "$rc" -eq 0 && grep -q 'substitute-silent-wait: PASS' "$fixture/client.log"; then
  echo "substitute-silent-wait: PASS (daemon kept serving during the silent helper; -A$rts_a)"
  exit 0
fi
echo "FAIL: substitute-silent-wait: the daemon froze during the silent helper (rc=$rc, -A$rts_a)" >&2
echo "--- daemon.log tail ---" >&2; tail -5 "$fixture/daemon.log" >&2 || true
exit 1
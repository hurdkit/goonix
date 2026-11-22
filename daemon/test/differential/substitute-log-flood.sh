#!/usr/bin/env bash
# goonix: substitute-log-drain regression (reviewer, 2026-11-22, zergling2 stall).
#
# The daemon spawns `guix substitute --query' with separate reply (fd 4) and log
# (stdout+stderr) pipes.  A helper that writes more than the pipe buffer (>64 KiB)
# of progress to its log descriptor BEFORE its reply blocks in write() once the
# log pipe fills; a daemon that reads only the reply pipe and never drains the log
# pipe then waits forever for a reply that never comes -> deadlock.  The C++
# daemon's getLineFromSubstituter selects on both descriptors and drains the log,
# so it answers.  This test points GUIX at a fake helper that floods the log pipe
# and requires the daemon to answer a substitute query within a deadline.
#
# Usage: substitute-log-flood.sh [DAEMON] [FIXTURE]
#   DAEMON defaults to $GOONIX_TEST_DAEMON or ./guix-daemon.  Run it with the
#   Haskell daemon (fails before the fix: the client times out) and with the C++
#   daemon (passes: it drains the log pipe).
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${1:-${GOONIX_TEST_DAEMON:-$root/guix-daemon}}
fixture=${2:-$root/.scratch/substitute-log-flood}
helper="$root/daemon/test/differential/substitute-log-flood-helper.sh"
chmod +x "$helper"

if test -e "$fixture"; then chmod -R u+rwX "$fixture" 2>/dev/null || true; rm -rf "$fixture"; fi
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
mkdir -p "$fixture/cache" "$fixture/etc"

export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix" GUIX_CONFIGURATION_DIRECTORY="$fixture/etc"
export XDG_CACHE_HOME="$fixture/cache" GUILE_AUTO_COMPILE=0
# The daemon resolves the substitute helper via GUIX (Goonix.Store.GuixProgram).
export GUIX="$helper"
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

goonix_start_capped "$root/pre-inst-env" env GUIX="$helper" "$daemon" --disable-chroot \
  --substitute-urls="$GUIX_BINARY_SUBSTITUTE_URL" --listen="$GUIX_DAEMON_SOCKET" \
  >"$fixture/daemon.log" 2>&1
pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid" 2>/dev/null || break; sleep .05; done
if ! test -S "$GUIX_DAEMON_SOCKET"; then
  echo "FAIL: daemon did not start"; tail -5 "$fixture/daemon.log" >&2; exit 1
fi

# The client must answer within the deadline.  GOONIX_TEST_TIMEOUT bounds it; a
# deadlocked daemon never answers and the capped client is killed (non-zero rc).
export GOONIX_TEST_TIMEOUT=${GOONIX_TEST_TIMEOUT:-30}
set +e
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile \
  "$root/daemon/test/differential/substitute-log-flood.scm" >"$fixture/client.log" 2>&1
rc=$?
set -e
cat "$fixture/client.log"
if test "$rc" -eq 0 && grep -q 'substitute-log-drain: PASS' "$fixture/client.log"; then
  echo "substitute-log-drain: PASS (daemon answered the flooded-log query)"
  exit 0
fi
echo "FAIL: substitute-log-drain: daemon did not answer within the deadline (rc=$rc)" >&2
echo "--- daemon.log tail ---" >&2; tail -5 "$fixture/daemon.log" >&2 || true
exit 1
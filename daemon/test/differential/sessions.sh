#!/usr/bin/env bash
# The sessions of a daemon, as the daemon reports them (operation 85).
#
# `guix processes' finds the sessions of the C++ daemon in /proc: one process
# per session, the client's PID as its second argument, its builds' lock
# files among its open files, its builders among its children.  The Haskell
# daemon is one process for all its sessions and shows none of that, so it
# keeps the same facts and answers operation 85 with them.  The C++ daemon
# does not know the operation.
#
# One client holds three connections: one builds, with a builder that waits
# to be let go, one is idle, one asks.  Checked for the Haskell daemon:
#   - the answer names the daemon's PID and the two other sessions, not the
#     asking one, each with this client's PID and a number of its own;
#   - the building session has the lock file of the output it builds and one
#     child, which /proc shows as a child of the daemon running the builder;
#     the idle session has neither;
#   - the connection that asked is still served;
#   - after the build no session holds anything, and a connection that was
#     closed is no longer listed.
# Checked for the C++ daemon, which is what a client of either has to cope
# with: the question is refused with "invalid operation 85" and the
# connection that asked is ended, by a session process that says so on the
# daemon's standard error.
# Checked for both: the building and the idle connection are served to the
# end, and a connection opened afterwards is served.
#
# Usage: sessions.sh [DAEMON] [FIXTURE]
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${1:-${GOONIX_TEST_DAEMON:-$root/guix-daemon}}
fixture=${2:-$root/.scratch/sessions}
if test -e "$fixture"; then chmod -R u+rwX "$fixture" 2>/dev/null || true; rm -rf "$fixture"; fi
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/s"
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix"
export XDG_CACHE_HOME="$fixture/cache" GUILE_AUTO_COMPILE=0
export SESSIONS_FIXTURE="$fixture"
mkdir -p "$fixture/cache"
# The builder waits by reading this with a timeout; it never gets a byte.
mkfifo "$fixture/tick"
exec 9<>"$fixture/tick"

# The Haskell daemon carries Goonix module symbols, the C++ one does not.
if test "$(grep -ac GoonixziStore "$daemon" || true)" -gt 0; then
  export SESSIONS_EXPECT=report
else
  export SESSIONS_EXPECT=refusal
fi

launcher= scope=
fail() {
  echo "FAIL: $*" >&2
  for log in daemon.log client.log; do
    if test -s "$fixture/$log"; then echo "--- $log" >&2; tail -20 "$fixture/$log" >&2; fi
  done
  exit 1
}
cleanup() {
  status=$?
  trap - EXIT
  {
    : > "$fixture/builder-may-finish"
    if test -n "$launcher"; then goonix_stop_capped "$launcher" "$scope"; fi
  } 2>/dev/null
  return "$status"
}
trap cleanup EXIT

goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --no-substitutes \
  --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1
launcher=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
for _ in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$launcher"; sleep .05; done
test -S "$GUIX_DAEMON_SOCKET" || fail "the daemon did not start"
# The launcher is `timeout'; the daemon is its child.
listening=$(pgrep -P "$launcher" | head -n 1)
test -n "$listening" || fail "no daemon process below the launcher $launcher"
test "$(readlink "/proc/$listening/exe")" = "$(readlink -f "$daemon")" \
  || fail "process $listening below the launcher is not the daemon"
export SESSIONS_DAEMON_PID=$listening

status=0
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile \
  "$root/daemon/test/differential/sessions.scm" >"$fixture/client.log" 2>&1 || status=$?
test "$status" -eq 0 || fail "the client ended with status $status"
grep -Fqx 'client done' "$fixture/client.log" || fail "the client did not reach its end"
grep -Fqx 'the other connections were served' "$fixture/client.log" \
  || fail "the client's other connections were not served"
if test "$SESSIONS_EXPECT" = report; then
  grep -Fqx 'sessions reported while a build runs' "$fixture/client.log" \
    || fail "no sessions were reported"
  grep -Fqx 'sessions reported after the build and after two clients left' "$fixture/client.log" \
    || fail "no sessions were reported after the build"
  echo "sessions reported by the daemon: PASS"
else
  grep -Fqx 'operation 85 refused, its connection ended' "$fixture/client.log" \
    || fail "operation 85 was not refused"
  grep -Fq 'invalid operation 85' "$fixture/daemon.log" \
    || fail "the daemon's session process did not report the operation it refused"
  echo "operation 85 refused, the other clients served: PASS"
fi

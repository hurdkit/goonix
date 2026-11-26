#!/usr/bin/env bash
# Regression: a daemon that is told to stop serves the clients it has.
#
# The C++ daemon serves each client from a process and a session of its own.
# SIGTERM, SIGINT or SIGHUP for its listening process ends that process at
# once and nobody new is accepted, but the connected clients keep their
# session processes: a build in flight is finished and its client gets the
# result.  The Haskell daemon serves every client from the process that
# listens.  It had no handler, so the signal ended the process and with it
# every client: a client in the middle of build-derivations read the end of
# its connection instead of a result.  Now it stops accepting, serves the
# connected clients until each has disconnected, and then ends by the signal.
#
# Checked here, with one client that builds and a second connection of the
# same client that stays idle:
#   - after the signal a new connection is refused;
#   - the build in flight ends and build-derivations returns to the client,
#     which finds the output valid on the same connection;
#   - the client leaves by itself, with success;
#   - the listening process is gone afterwards, ended by the signal.
# These hold for both daemons.  For the Haskell daemon, also what is written
# in daemon/DIFFERENCES.md: the listening process is still there while the
# build runs after the signal, and while only the idle connection is left.
#
# With `ignored' the daemon is started with the signal ignored, as `nohup'
# starts it for SIGHUP and a shell without job control starts a background
# command for SIGINT.  The C++ listening process installs no handler, so the
# signal stays ignored; the Haskell runtime takes SIGINT whatever it inherits,
# and the daemon ended.  Checked for both daemons: after the signal the
# daemon still accepts a connection, and the client's build ends as usual.
#
# With `abandon' the client is ended instead of being let finish: its build
# is in flight, the daemon has been told to stop, and now nobody is waiting
# for the build.  The daemon has to stop the builder, end by the signal, and
# leave no process behind.
#
# Usage: stop-drain.sh [DAEMON] [FIXTURE] [SIGNAL] [stop|ignored|abandon]
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${1:-${GOONIX_TEST_DAEMON:-$root/guix-daemon}}
fixture=${2:-$root/.scratch/stop-drain}
signal=${3:-TERM}
mode=${4:-stop}
case "$signal" in
  TERM) ended_by=143 ;; INT) ended_by=130 ;; HUP) ended_by=129 ;;
  *) echo "stop-drain: SIGNAL is TERM, INT or HUP, not $signal" >&2; exit 2 ;;
esac
# The daemon is a background command of this script, which has no job
# control: it would inherit SIGINT as ignored.  Say what it inherits.
case "$mode" in
  stop|abandon) disposition=--default-signal ;;
  ignored) disposition=--ignore-signal ;;
  *) echo "stop-drain: the mode is stop, ignored or abandon, not $mode" >&2; exit 2 ;;
esac
if test -e "$fixture"; then chmod -R u+rwX "$fixture" 2>/dev/null || true; rm -rf "$fixture"; fi
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/s"
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix"
export XDG_CACHE_HOME="$fixture/cache" GUILE_AUTO_COMPILE=0
export STOP_DRAIN_FIXTURE="$fixture"
mkdir -p "$fixture/cache"
# The builder waits by reading this with a timeout; it never gets a byte.
mkfifo "$fixture/tick"
exec 9<>"$fixture/tick"

# The Haskell daemon carries Goonix module symbols, the C++ one does not.
if test "$(grep -ac GoonixziStore "$daemon" || true)" -gt 0; then one_process=yes; else one_process=no; fi

launcher= scope= client= client_scope= listening=
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
  # Let a builder that is still waiting go, then the client, then the daemon.
  # The shell's own notes about the jobs this ends are not part of the result.
  {
    : > "$fixture/builder-may-finish"
    : > "$fixture/client-may-leave"
    if test -n "$client"; then goonix_stop_capped "$client" "$client_scope"; fi
    if test -n "$listening"; then kill -KILL "$listening" || true; fi
    if test -n "$launcher"; then goonix_stop_capped "$launcher" "$scope"; fi
  } 2>/dev/null
  return "$status"
}
trap cleanup EXIT
alive() { kill -0 "$1" 2>/dev/null; }
# await SECONDS COMMAND...: true as soon as COMMAND succeeds.
await() {
  local tries=$(( $1 * 20 )); shift
  for _ in $(seq 1 "$tries"); do
    if "$@"; then return 0; fi
    sleep .05
  done
  return 1
}
# Try to connect: status 0 when the daemon accepts, 1 when it refuses.
try_connect() {
  guile --no-auto-compile -c '
    (let ((port (socket PF_UNIX SOCK_STREAM 0)))
      (catch (quote system-error)
        (lambda () (connect port AF_UNIX (cadr (command-line))) (exit 0))
        (lambda arguments
          (exit (if (= ECONNREFUSED (system-error-errno arguments)) 1 2)))))' \
    "$GUIX_DAEMON_SOCKET"
}
refused() { local status=0; try_connect || status=$?; test "$status" -eq 1; }

goonix_start_capped "$root/pre-inst-env" env "$disposition=$signal" \
  "$daemon" --disable-chroot --no-substitutes \
  --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1
launcher=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
await 15 test -S "$GUIX_DAEMON_SOCKET" || fail "the daemon did not start"
# The launcher is `timeout'; the daemon is its child.  Taken before any client
# connects: the C++ daemon's session processes carry the same command line.
listening=$(pgrep -P "$launcher" | head -n 1)
test -n "$listening" || fail "no daemon process below the launcher $launcher"
test "$(readlink "/proc/$listening/exe")" = "$(readlink -f "$daemon")" \
  || fail "process $listening below the launcher is not the daemon"

goonix_start_capped "$root/pre-inst-env" guile --no-auto-compile \
  "$root/daemon/test/differential/stop-drain.scm" >"$fixture/client.log" 2>&1
client=$GOONIX_TEST_PID client_scope=$GOONIX_TEST_SCOPE
await 120 test -e "$fixture/builder-started" || fail "the builder did not start"
alive "$client" || fail "the client ended before its build"

kill -s "$signal" "$listening"
if test "$mode" = ignored; then
  sleep 1
  alive "$listening" || fail "the daemon ended by a SIG$signal it was started to ignore"
  try_connect || fail "no connection is accepted after an ignored SIG$signal"
  : > "$fixture/builder-may-finish"
  await 60 test -e "$fixture/client-built" || fail "the client got no result for its build"
  : > "$fixture/client-may-leave"
  status=0; wait "$client" || status=$?
  client=
  test "$status" -eq 0 || fail "the client ended with status $status"
  alive "$listening" || fail "the daemon ended after its client left"
  try_connect || fail "no connection is accepted after the client left"
  echo "SIG$signal ignored at start stays ignored: PASS"
  exit 0
fi
await 10 refused || fail "a new connection is still accepted after SIG$signal"
if test "$one_process" = yes; then
  alive "$listening" || fail "the daemon ended while a client was building"
fi
test ! -e "$fixture/client-built" || fail "the build returned before the builder was let go"
alive "$client" || fail "the client ended with its build in flight"
left_behind() { pgrep -f -- "$fixture/store/" >/dev/null; }

if test "$mode" = abandon; then
  left_behind || fail "no builder is running before the client is ended"
  goonix_stop_capped "$client" "$client_scope" 2>/dev/null
  client=
  await 30 eval '! alive "$listening"' || fail "the daemon is still there after its only client was ended"
  listening=
  status=0; wait "$launcher" 2>/dev/null || status=$?
  launcher=
  test "$status" -eq "$ended_by" \
    || fail "the daemon ended with status $status, not $ended_by (SIG$signal)"
  if ! await 15 eval '! left_behind'; then
    pgrep -af -- "$fixture/store/" >&2 || true
    fail "a process of this store is left"
  fi
  test ! -e "$fixture/client-built" || fail "the abandoned build returned a result"
  echo "client ended while the daemon was stopping (SIG$signal): PASS"
  exit 0
fi

: > "$fixture/builder-may-finish"
await 60 test -e "$fixture/client-built" || fail "the client got no result for the build in flight"
grep -Fqx 'build returned, output valid' "$fixture/client.log" \
  || fail "the client did not find its output valid"
if test "$one_process" = yes; then
  # The building connection is done; the idle one is still open.
  sleep 1
  alive "$listening" || fail "the daemon ended while a client was connected"
fi

: > "$fixture/client-may-leave"
status=0; wait "$client" || status=$?
client=
test "$status" -eq 0 || fail "the client ended with status $status"
grep -Fqx 'client done' "$fixture/client.log" || fail "the client did not reach its end"

await 15 eval '! alive "$listening"' || fail "the daemon is still there after its last client left"
listening=
status=0; wait "$launcher" 2>/dev/null || status=$?
launcher=
test "$status" -eq "$ended_by" \
  || fail "the daemon ended with status $status, not $ended_by (SIG$signal)"
if left_behind; then
  pgrep -af -- "$fixture/store/" >&2 || true
  fail "a process of this store is left"
fi
echo "stop requested with a build in flight (SIG$signal): PASS"

#!/usr/bin/env bash
# Kill a sandbox helper during a fixed-output build. Both of its children
# must disappear; this is the explicit HS-6 cancellation/cleanup regression.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
. "$root/daemon/test/lib.sh"
fixture=${1:-$root/.scratch/hs6-helper-kill}
: "${GOONIX_REAL_SLIRP4NETNS:?set to the test slirp4netns executable}"
: "${GOONIX_BOOTSTRAP_SLEEP:?set to an x86_64 bootstrap sleep executable}"
if test -e "$fixture"; then chmod -R u+rwX "$fixture" 2>/dev/null || true; rm -rf "$fixture"; fi
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
export GOONIX_TEST_TIMEOUT=60
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix" GUIX_CONFIGURATION_DIRECTORY="$fixture/etc"
export HS6_KILL_FIXTURE="$fixture"
export GUIX_SLIRP4NETNS="$GOONIX_REAL_SLIRP4NETNS"
export GUILE_AUTO_COMPILE=0
export GUIX_SANDBOX=${GOONIX_SANDBOX_HELPER:-$root/guix-sandbox}
daemon=${GOONIX_HS_DAEMON:-$root/guix-daemon}
pid= scope= client=
cleanup() {
  status=$?
  trap - EXIT
  if test -n "$client"; then kill "$client" 2>/dev/null || true; wait "$client" 2>/dev/null || true; fi
  if test -n "$pid"; then goonix_stop_capped "$pid" "$scope" || status=$?; fi
  if test "$status" -eq 0; then
    chmod -R u+rwX "$fixture" 2>/dev/null || true
    rm -rf "$fixture"
  fi
  return "$status"
}
trap cleanup EXIT
# Only start this probe's synthetic fixed-output build, never a package set.
goonix_start_capped "$root/pre-inst-env" "$daemon" --no-substitutes --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1
pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
test -S "$GUIX_DAEMON_SOCKET"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/seed-restore.scm" >"$fixture/seed.log" 2>&1
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/sandbox-helper-cleanup.scm" >"$fixture/client.log" 2>&1 &
client=$!
# @ build-started carries the helper's PID in the daemon's PID namespace.
for i in $(seq 1 600); do
  helper=$(sed -n 's/^@ build-started .* \([0-9][0-9]*\)HS6 builder ready.*/\1/p' "$fixture/client.log" | tail -1)
  test -n "$helper" && break
  kill -0 "$client"
  sleep .05
done
test -n "$helper"
test "$(readlink -f "/proc/$helper/exe")" = "$(readlink -f "$GUIX_SANDBOX")"
builder_path=$(cat "$fixture/builder-path")
sleeper=$(sed -n "s/.*exec '\\([^']*\\)' 600.*/\\1/p" "$builder_path")
test -n "$sleeper"
slirp_program=$(readlink -f "$GOONIX_REAL_SLIRP4NETNS")
# Namespace-local $$ and comm are not host identifiers. Walk the helper's
# descendants in the daemon's initial PID namespace and match /proc/PID/exe.
tree="$helper"
frontier="$helper"
while test -n "$frontier"; do
  next=
  for parent in $frontier; do
    children=$(ps -eo pid=,ppid= | awk -v parent="$parent" '$2 == parent {print $1}')
    test -z "$children" || next="$next $children"
  done
  tree="$tree $next"
  frontier=$next
done
pids=$(echo $tree | tr ' ' ',')
ps -p "$pids" -o pid=,ppid=,pgid=,stat=,args= > "$fixture/processes-before-kill"
builder= slirp=
for process in $tree; do
  executable=$(readlink "/proc/$process/exe" 2>/dev/null || true)
  if test "$executable" = "$sleeper"; then
    test -z "$builder"
    builder=$process
  elif test "$executable" = "$slirp_program"; then
    test -z "$slirp"
    slirp=$process
  fi
done
test -n "$builder" -a -n "$slirp"
test "$builder" != "$slirp"
for process in "$helper" "$slirp" "$builder"; do kill -0 "$process"; done
kill -KILL "$helper"
for i in $(seq 1 600); do
  alive=
  for process in "$helper" "$slirp" "$builder"; do
    test ! -e "/proc/$process" || alive="$alive $process"
  done
  test -z "$alive" && break
  sleep .05
done
if test -n "$alive"; then
  printf 'processes survived helper kill:%s\n' "$alive" >&2
  ps -p $(echo $alive | tr ' ' ',') -o pid=,ppid=,pgid=,stat=,wchan=,args= >&2 || true
  exit 1
fi
if wait "$client"; then
  printf 'fixed-output client unexpectedly succeeded\n' >&2
  exit 1
fi
client=
printf 'HS-6 sandbox helper-kill cleanup: PASS (helper=%s slirp=%s builder=%s)\n' "$helper" "$slirp" "$builder"

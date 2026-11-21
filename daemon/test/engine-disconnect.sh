#!/usr/bin/env bash
# Disconnect a client while two builders run; check children, locks and roots.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${GOONIX_HS_DAEMON:-$root/guix-daemon}
out=${1:-$root/.scratch/hs4-engine-disconnect}
mkdir -p "$out"
fixture=$(mktemp -d /tmp/goonix-disconnect-XXXXXX)
pid= scope=
cleanup() {
  status=$?
  trap - EXIT
  exec 9>&- 2>/dev/null || true
  if test -n "$pid"; then goonix_stop_capped "$pid" "$scope" || status=$?; fi
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
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/s"
export HS4_SCHEDULER_FIXTURE="$fixture" GUILE_AUTO_COMPILE=0
mkdir -p "$NIX_STORE_DIR" "$GUIX_DATABASE_DIRECTORY" "$GUIX_STATE_DIRECTORY"
mkfifo "$fixture/tick"
exec 9<>"$fixture/tick"
goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --no-substitutes --listen="$GUIX_DAEMON_SOCKET" >"$out/daemon.log" 2>&1
pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
test -S "$GUIX_DAEMON_SOCKET"
# Timeout is a failed test, not permission to leave builders running.
goonix_start_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/engine-disconnect.scm" >"$out/client.log" 2>&1
client=$GOONIX_TEST_PID client_scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 1500); do
  test -s "$fixture/disconnect-left.pid" && test -s "$fixture/disconnect-right.pid" && break
  kill -0 "$client"
  sleep .01
done
for name in disconnect-left disconnect-right; do
  for suffix in pid child.pid output drv; do
    test -s "$fixture/$name.$suffix" || { echo "missing disconnect fixture marker: $name.$suffix" >&2; cat "$out/client.log"; exit 1; }
  done
done
left=$(cat "$fixture/disconnect-left.pid")
right=$(cat "$fixture/disconnect-right.pid")
left_child=$(cat "$fixture/disconnect-left.child.pid")
right_child=$(cat "$fixture/disconnect-right.child.pid")
left_output=$(cat "$fixture/disconnect-left.output")
right_output=$(cat "$fixture/disconnect-right.output")
kill -0 "$left" "$right" "$left_child" "$right_child"
roots_before=$(find "$fixture/var/temproots" -mindepth 1 -maxdepth 1 -type f | wc -l)
test "$roots_before" -ge 1
goonix_stop_capped "$client" "$client_scope"
for i in $(seq 1 1000); do
  alive=0
  for child in "$left" "$right" "$left_child" "$right_child"; do
    kill -0 "$child" 2>/dev/null && alive=1
  done
  test "$alive" -eq 0 && break
  sleep .01
done
for child in "$left" "$right" "$left_child" "$right_child"; do
  if kill -0 "$child" 2>/dev/null; then
    echo "builder or child survived client disconnect: $child" >&2
    exit 1
  fi
done
for output in "$left_output" "$right_output"; do
  test ! -e "$output" || { echo "partial output survived disconnect: $output" >&2; exit 1; }
  test ! -e "$output.lock" || { echo "output lock file survived disconnect: $output.lock" >&2; exit 1; }
done
for i in $(seq 1 1000); do
  if test -z "$(find "$fixture/var/temproots" -mindepth 1 -maxdepth 1 -type f -print -quit)" &&
     test -z "$(find "$fixture/store" -name '*.lock' -print -quit)"; then break; fi
  sleep .01
done
test -z "$(find "$fixture/var/temproots" -mindepth 1 -maxdepth 1 -type f -print -quit)" || { echo 'client temporary roots survived disconnect cleanup' >&2; exit 1; }
test -z "$(find "$fixture/store" -name '*.lock' -print -quit)" || { echo 'store lock files survived disconnect cleanup' >&2; exit 1; }
kill -0 "$pid" || { echo 'daemon died during disconnect cleanup' >&2; exit 1; }
printf 'HS-4 disconnect kills builder trees and removes locks, roots and partial outputs: PASS\n'
touch "$fixture/release-builders"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/engine-disconnect-retry.scm" >"$out/retry.log" 2>&1 || { cat "$out/retry.log"; exit 1; }
cat "$out/retry.log"
printf 'HS-4 new client rebuilds disconnected derivations: PASS\n'
# A build that has already finished must retain its output when its client goes.
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/engine-disconnect-completed.scm" >"$out/completed.log" 2>&1 || { cat "$out/completed.log"; exit 1; }
completed_output=$(cat "$fixture/completed-output")
test -f "$completed_output" || { echo 'completed output vanished after client close' >&2; exit 1; }
completed_builder=$(cat "$fixture/completed-builder.pid")
kill -0 "$completed_builder" 2>/dev/null && { echo 'completed builder was killed after client close' >&2; exit 1; }
printf 'HS-4 completed build survives its client closing: PASS\n'
# The second client is independent: the first client's EOF must not cancel it.
goonix_start_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/engine-disconnect-owner.scm" >"$out/owner.log" 2>&1
owner=$GOONIX_TEST_PID owner_scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 1000); do test -e "$fixture/shared-started" && break; kill -0 "$owner"; sleep .01; done
test -e "$fixture/shared-started" || { cat "$out/owner.log"; exit 1; }
goonix_start_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/engine-disconnect-waiter.scm" >"$out/waiter.log" 2>&1
waiter=$GOONIX_TEST_PID waiter_scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 1000); do test -e "$fixture/waiter-started" && break; kill -0 "$waiter"; sleep .01; done
test -e "$fixture/waiter-started" || { cat "$out/waiter.log"; exit 1; }
goonix_stop_capped "$owner" "$owner_scope"
kill -0 "$waiter" || { echo 'second client died with first client' >&2; exit 1; }
touch "$fixture/release-shared"
for i in $(seq 1 1000); do test -e "$fixture/waiter-finished" && break; kill -0 "$waiter"; sleep .01; done
test -e "$fixture/waiter-finished" || { cat "$out/waiter.log"; echo 'second client did not finish after first disconnect' >&2; exit 1; }
goonix_stop_capped "$waiter" "$waiter_scope"
printf 'HS-4 second client survives first client disconnect and obtains output: PASS\n'

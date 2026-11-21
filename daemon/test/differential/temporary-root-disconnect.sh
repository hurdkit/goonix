#!/usr/bin/env bash
# Client B stays connected while client A's temporary root expires.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${1:?Haskell daemon required}
out=${2:-$root/.scratch/hs7-temporary-roots-disconnect}
rm -rf "$out"
mkdir -p "$out"
out=$(CDPATH= cd -- "$out" && pwd)
fixture=$(mktemp -d /tmp/goonix-disconnect-XXXXXX)
socket=$fixture/s
daemon_pid= daemon_scope= keeper_pid= keeper_scope=
cleanup() {
  status=$?
  trap - EXIT
  if test -n "$keeper_pid"; then goonix_stop_capped "$keeper_pid" "$keeper_scope" || status=$?; fi
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
export HS7_FIXTURE="$fixture" HS7_PHASE=hold
export HS7_HOLDER_SOCKET="$socket" HS7_COLLECTOR_SOCKET="$socket"
unset GUIX
mkdir -p "$NIX_STORE_DIR" "$GUIX_DATABASE_DIRECTORY" "$GUIX_STATE_DIRECTORY"
goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --listen="$socket" >"$out/daemon.log" 2>&1
daemon_pid=$GOONIX_TEST_PID daemon_scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 500); do test -S "$socket" && break; kill -0 "$daemon_pid"; sleep .01; done
test -S "$socket"
goonix_start_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/differential/temporary-root-holder.scm" >"$out/keeper.log" 2>&1
keeper_pid=$GOONIX_TEST_PID keeper_scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 1500); do test -s "$fixture/holder-ready" && break; kill -0 "$keeper_pid"; sleep .01; done
test -s "$fixture/holder-ready"
cp "$fixture/held-path" "$fixture/keeper-path"
keeper_root=
for i in $(seq 1 1500); do
  keeper_root=$(grep -lF -z "$(cat "$fixture/keeper-path")" "$fixture/var/temproots"/* 2>/dev/null || true)
  test -n "$keeper_root" && break
  sleep .01
done
test -f "$keeper_root"
echo "$keeper_root" > "$out/keeper-root-name"
cp "$keeper_root" "$out/keeper-root-before"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/differential/temporary-root-disconnect.scm" >"$out/disconnect.log" 2>&1
for i in $(seq 1 1500); do
  test "$(find "$fixture/var/temproots" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 1 && break
  sleep .01
done
test -f "$keeper_root"
cmp "$out/keeper-root-before" "$keeper_root"
test "$(find "$fixture/var/temproots" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 1
cp -a "$fixture/var/temproots" "$out/temproots-after-disconnect"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/differential/temporary-root-disconnect-collect.scm" >"$out/collect.log" 2>&1
test -f "$keeper_root"
cmp "$out/keeper-root-before" "$keeper_root"
kill -0 "$keeper_pid"
printf 'HS-7 disconnected temporary-root expiry with live client: PASS\n'

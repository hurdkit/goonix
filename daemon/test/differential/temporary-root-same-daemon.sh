#!/usr/bin/env bash
# Two clients of ONE Haskell daemon: a live root must survive collection.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${1:?Haskell daemon required}
out=${2:-$root/.scratch/hs7-temporary-roots-same}
mkdir -p "$out"
out=$(CDPATH= cd -- "$out" && pwd)
fixture=$(mktemp -d /tmp/goonix-same-roots-XXXXXX)
socket=$fixture/s
daemon_pid= daemon_scope= holder_pid= holder_scope=
cleanup() {
  status=$?
  trap - EXIT
  if test -n "$holder_pid"; then goonix_stop_capped "$holder_pid" "$holder_scope" || status=$?; fi
  if test -n "$daemon_pid"; then goonix_stop_capped "$daemon_pid" "$daemon_scope" || status=$?; fi
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
kill -0 "$daemon_pid"
goonix_start_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/differential/temporary-root-holder.scm" >"$out/holder.log" 2>&1
holder_pid=$GOONIX_TEST_PID holder_scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 1500); do test -s "$fixture/holder-ready" && break; kill -0 "$holder_pid"; sleep .01; done
test -s "$fixture/holder-ready"
test "$(find "$fixture/var/temproots" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 1
root_file=$(find "$fixture/var/temproots" -mindepth 1 -maxdepth 1 -type f)
cp "$root_file" "$out/root-before"
HS7_PHASE=collect GOONIX_TEST_TIMEOUT=40 goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/differential/temporary-root-collect.scm" >"$out/collect.log" 2>&1
kill -0 "$daemon_pid" "$holder_pid"
test -e "$(cat "$fixture/held-path")"
test -f "$root_file"
cp -a "$fixture/var/temproots" "$out/temproots-after"
cmp "$out/root-before" "$root_file"
printf 'HS-7 concurrent temporary roots hs-hs: PASS\n'

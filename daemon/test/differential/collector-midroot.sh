#!/usr/bin/env bash
# Collector stage (DECISIONS.md point 3): a root registered by a NEW client while
# a collection runs keeps its item; the new client does not wait for the whole
# collection.  One Haskell daemon, a marker-blocked builder, a collector thread,
# and a second client that roots an item mid-collection.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${1:?Haskell daemon required}
out=${2:-$root/.scratch/collector-midroot}
mkdir -p "$out"
find "$out" -mindepth 1 -maxdepth 1 -exec chmod -R u+rwX {} + 2>/dev/null || true
find "$out" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
out=$(CDPATH= cd -- "$out" && pwd)
fixture=$(mktemp -d /tmp/goonix-col-midroot-XXXXXX)
socket=$fixture/s
daemon_pid= daemon_scope= probe_pid= probe_scope=
cleanup() {
  status=$?
  trap - EXIT
  test -e "$fixture/release-builder" && : || touch "$fixture/release-builder"
  if test -n "$probe_pid"; then goonix_stop_capped "$probe_pid" "$probe_scope" || status=$?; fi
  if test -n "$daemon_pid"; then goonix_stop_capped "$daemon_pid" "$daemon_scope" || status=$?; fi
  exec 9>&- || status=$?
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
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix"
unset GUIX
mkdir -p "$NIX_STORE_DIR" "$GUIX_DATABASE_DIRECTORY" "$GUIX_STATE_DIRECTORY"
mkfifo "$fixture/tick"
exec 9<>"$fixture/tick"
goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --no-substitutes --listen="$socket" >"$out/daemon.log" 2>&1
daemon_pid=$GOONIX_TEST_PID daemon_scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 500); do test -S "$socket" && break; kill -0 "$daemon_pid"; sleep .01; done
test -S "$socket"
kill -0 "$daemon_pid"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/differential/collector-midroot.scm" >"$out/probe.log" 2>&1
grep -q 'collector mid-collection root preservation: PASS' "$out/probe.log"
printf 'collector mid-collection root preservation: PASS\n'
cleanup
trap - EXIT
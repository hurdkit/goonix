#!/usr/bin/env bash
# HS-4 semantic regressions on real client requests.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
. "$root/daemon/test/lib.sh"
fixture=${1:-$root/.scratch/hs4-engine-semantics}
daemon=${GOONIX_HS_DAEMON:-$root/guix-daemon}
export GOONIX_TEST_TIMEOUT=${GOONIX_TEST_TIMEOUT:-120}
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix" GUIX_CONFIGURATION_DIRECTORY="$fixture/etc"
export GUILE_AUTO_COMPILE=0 HS4_SCHEDULER_FIXTURE="$fixture"
export GUIX_BINARY_SUBSTITUTE_URL="file://$fixture/substituter-data"
export GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES=yes
export XDG_CACHE_HOME="$fixture/cache"
pid= scope=
cleanup() {
  status=$?
  trap - EXIT
  exec 9>&- 2>/dev/null || true
  if test -n "$pid"; then goonix_stop_capped "$pid" "$scope" || status=$?; fi
  if test "$status" -eq 0; then
    chmod -R u+rwX "$fixture" 2>/dev/null || true
    rm -rf "$fixture"
  fi
  return "$status"
}
trap cleanup EXIT
if test -e "$fixture"; then chmod -R u+rwX "$fixture" 2>/dev/null || true; rm -rf "$fixture"; fi
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
mkdir -p "$fixture/substituter-data" "$fixture/cache"
mkfifo "$fixture/tick"
exec 9<>"$fixture/tick"
goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --substitute-urls="$GUIX_BINARY_SUBSTITUTE_URL" --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1
pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
test -S "$GUIX_DAEMON_SOCKET"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/seed-restore.scm" >"$fixture/seed.log" 2>&1
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/engine-semantics.scm" >"$fixture/client.log" 2>&1
cat "$fixture/client.log"
for marker in \
  'HS-4 valid parent is lazy: PASS' \
  'HS-4 substituted parent is lazy: PASS' \
  'HS-4 selected-output union: PASS' \
  'HS-4 failure before waiting builder release: PASS' \
  'HS-4 keep-going completes independent builder: PASS' \
  'HS-4 zero local slots: PASS'; do
  grep -F "$marker" "$fixture/client.log" >/dev/null
done
if test -f "$fixture/waiting-pid"; then
  waiting=$(cat "$fixture/waiting-pid")
  if kill -0 "$waiting" 2>/dev/null; then
    printf 'waiting builder still running: %s\n' "$waiting" >&2
    exit 1
  fi
fi

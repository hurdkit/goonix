#!/usr/bin/env bash
# HS-12 goal-sharing failure rule: only SUCCESS is shared.  A with
# max-silent-time 1 on a builder that sleeps 3 s, and B with no limit, both on
# the same derivation: A fails (its silent-time limit), B succeeds (its own
# attempt with its own settings).  With the pre-fix goal sharing B would take
# A's failure instead of building again.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
. "$root/daemon/test/lib.sh"
fixture=${1:-$root/.scratch/hs12-goal-failure}
daemon=${GOONIX_HS_DAEMON:-$root/guix-daemon}
export GOONIX_TEST_TIMEOUT=${GOONIX_TEST_TIMEOUT:-120}
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix" GUIX_CONFIGURATION_DIRECTORY="$fixture/etc"
export GUILE_AUTO_COMPILE=0 HS12_GOAL_FIXTURE="$fixture"
export XDG_CACHE_HOME="$fixture/cache"
pid= scope=
cleanup() {
  status=$?
  trap - EXIT
  test -e "$fixture/release-builder" && : || touch "$fixture/release-builder"
  exec 9>&- 2>/dev/null || true
  if test -n "$pid"; then goonix_stop_capped "$pid" "$scope" || status=$?; fi
  if test "$status" -ne 0; then cp -a "$fixture" "$fixture.fail" 2>/dev/null || true; fi
  if test "$status" -eq 0; then
    chmod -R u+rwX "$fixture" 2>/dev/null || true
    rm -rf "$fixture"
  fi
  return "$status"
}
trap cleanup EXIT
if test -e "$fixture"; then chmod -R u+rwX "$fixture" 2>/dev/null || true; rm -rf "$fixture"; fi
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
mkdir -p "$fixture/cache"
mkfifo "$fixture/tick"
exec 9<>"$fixture/tick"
goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --no-substitutes --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1
pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
test -S "$GUIX_DAEMON_SOCKET"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/seed-restore.scm" >"$fixture/seed.log" 2>&1
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/engine-goal-failure.scm" >"$fixture/client.log" 2>&1
cat "$fixture/client.log"
grep -q 'HS-12 goal failure rule: PASS' "$fixture/client.log"
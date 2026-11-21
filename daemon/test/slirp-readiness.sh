#!/usr/bin/env bash
# Readiness failure probe: a slirp process that dies must not hang setup.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
. "$root/daemon/test/lib.sh"
fixture=${1:-$root/.scratch/hs6-slirp-readiness}
if test -e "$fixture"; then chmod -R u+rwX "$fixture" 2>/dev/null || true; rm -rf "$fixture"; fi
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
# Keep the daemon socket below the Unix-domain path limit.
live=$(mktemp -d /tmp/goonix-slirp-ready-XXXXXX)
mkdir -p "$live/store" "$live/db" "$live/var"
cp -a "$fixture/store/." "$live/store/"
cp -a "$fixture/db/." "$live/db/"
cp -a "$fixture/var/." "$live/var/"
export GOONIX_TEST_TIMEOUT=45
export NIX_STORE_DIR="$live/store" GUIX_DATABASE_DIRECTORY="$live/db"
export GUIX_STATE_DIRECTORY="$live/var" GUIX_DAEMON_SOCKET="$live/s"
export GUIX_LOG_DIRECTORY="$live/var/log/guix" GUIX_CONFIGURATION_DIRECTORY="$live/etc"
export GUIX="$root/scripts/guix" GUILE_AUTO_COMPILE=0
export GUIX_SANDBOX="$GOONIX_SANDBOX_HELPER"
export GUIX_SLIRP4NETNS="$root/daemon/test/fail-slirp.sh"
goonix_start_capped "$root/pre-inst-env" "${GOONIX_HS_DAEMON:-$root/guix-daemon}" --no-substitutes --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1
pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
cleanup() {
  status=$?
  trap - EXIT
  if test -n "$pid"; then goonix_stop_capped "$pid" "$scope" || status=$?; fi
  if test "$status" -eq 0; then
    chmod -R u+rwX "$fixture" "$live" 2>/dev/null || true
    rm -rf "$fixture" "$live"
  fi
  return "$status"
}
trap cleanup EXIT
for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
test -S "$GUIX_DAEMON_SOCKET"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/seed-restore.scm" >"$fixture/seed.log" 2>&1
export HS6_KILL_FIXTURE="$live"
: "${GOONIX_SANDBOX_HELPER:?set to the helper built from this source}"
: "${GOONIX_BOOTSTRAP_SLEEP:?set to a static x86_64 sleep executable}"
export GOONIX_BOOTSTRAP_SLEEP
set +e
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/sandbox-helper-cleanup.scm" >"$fixture/client.log" 2>&1
status=$?
set -e
test "$status" != 0 -a "$status" != 124
# setupSlirp must fail itself, rather than relying on the daemon timeout.
found=0
while IFS= read -r -d '' log; do
  if gzip -cd "$log" | grep -E 'slirp4netns (exited before becoming ready|closed its readiness channel|did not become ready)'; then found=1; fi
done < <(find "$live/var/log" -type f -name '*.drv.gz' -print0)
test "$found" = 1
printf 'HS-6 slirp readiness failure: PASS (prompt setup error)\n'

#!/usr/bin/env bash
# Regression: a self-referencing store output reports itself in queryReferences.
# Usage: self-reference.sh [DAEMON] [FIXTURE]
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${1:-${GOONIX_TEST_DAEMON:-$root/guix-daemon}}
fixture=${2:-$root/.scratch/hs-self-reference}
if test -e "$fixture"; then chmod -R u+rwX "$fixture" 2>/dev/null || true; rm -rf "$fixture"; fi
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
export GUIX="$root/scripts/guix"
export GUILE_AUTO_COMPILE=0
rm -f "$GUIX_DAEMON_SOCKET"
test ! -e "$GUIX_DAEMON_SOCKET"
goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1
pid=$GOONIX_TEST_PID
daemon_scope=$GOONIX_TEST_SCOPE
trap 'goonix_stop_capped "$pid" "$daemon_scope"' EXIT
for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
test -S "$GUIX_DAEMON_SOCKET"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/differential/self-reference.scm"
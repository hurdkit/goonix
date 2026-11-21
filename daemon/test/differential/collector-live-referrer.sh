#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
fixture=${1:-$root/.scratch/hs7-live-referrer}
daemon=${GOONIX_TEST_DAEMON:-$root/guix-daemon}
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
export HS7_ROOT="$fixture" GUIX="$root/scripts/guix"
goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1
pid=$GOONIX_TEST_PID
daemon_scope=$GOONIX_TEST_SCOPE
trap 'goonix_stop_capped "$pid" "$daemon_scope"' EXIT
for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
test -S "$GUIX_DAEMON_SOCKET"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/differential/collector-live-referrer.scm"

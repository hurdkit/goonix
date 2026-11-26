#!/usr/bin/env bash
# Regression: a request for an unresolved content-addressed derivation goes
# through its inputs even when the derivation's own choice is valid.
#
# C++ prepareGoonixGoal never finishes an unresolved goal: it realises the
# inputs, resolves, and the RESOLVED derivation is done or built.  So an input
# whose output was collected is realised again by a request for its dependent,
# in normal mode and before a check.  The Haskell decision finished an
# unresolved goal as soon as its choices were valid; the input stayed
# collected ("derivation output `out' ... is not realised" for the next query
# of it), and a check of the dependent resolved against the missing input and
# failed with that error.
#
# Usage: ca-collected-input.sh [DAEMON] [FIXTURE]
# Runs against DAEMON (default the daemon of this tree); both daemons pass.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${1:-${GOONIX_TEST_DAEMON:-$root/guix-daemon}}
fixture=${2:-$root/.scratch/ca-collected-input}
if test -e "$fixture"; then chmod -R u+rwX "$fixture" 2>/dev/null || true; rm -rf "$fixture"; fi
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
mkdir -p "$fixture/etc" "$fixture/cache"
# The daemon signs build records; these are the test suite's keys.
cp "$root/tests/keys/openpgp/signing-key.sec" "$root/tests/keys/openpgp/signing-key.pub" "$fixture/etc/"
chmod 0400 "$fixture/etc/signing-key.sec"
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix" GUIX_CONFIGURATION_DIRECTORY="$fixture/etc"
export XDG_CACHE_HOME="$fixture/cache" GUILE_AUTO_COMPILE=0
export CA_COLLECTED_INPUT_FIXTURE="$fixture"
pid= scope=
cleanup() {
  status=$?
  trap - EXIT
  if test -n "$pid"; then goonix_stop_capped "$pid" "$scope"; fi
  return "$status"
}
trap cleanup EXIT
goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --no-substitutes \
  --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1
pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
test -S "$GUIX_DAEMON_SOCKET"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile \
  "$root/daemon/test/differential/ca-collected-input.scm" | tee "$fixture/client.log"
grep -Fq 'collected input realised again: PASS' "$fixture/client.log"

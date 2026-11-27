#!/usr/bin/env bash
# Regression: the references of a built output are found among the paths of
# its inputs' closure and its own outputs, as in C++, never among every valid
# store path.
#
# C++ registerOutputs scans an output for the paths of allPaths: the outputs
# and the closure of the selected outputs of the input derivations and of the
# sources (DerivationGoal::inputsRealised, nix/libstore/build.cc), or for a
# content-addressed goal the closure of the sources and the builder
# (goonixInputPaths, nix/libstore/build-ca.cc).  The Haskell daemon scanned
# for every valid path, so an output whose contents name a derivation file
# that is in the store but no input (a comment in a Scheme module of a Guix
# package was enough) referred to that file.  A references graph over such an
# output then included the outputs of that derivation and of all its inputs,
# down to sources that are not in the store, and the build of the graph's
# dependent failed with "path `...' is not valid" in a store that keeps
# packages but not their sources.
#
# The outputs of the build are among those paths too, so an output may refer
# to a sibling output; C++ registers them together (registerValidPaths), the
# Haskell daemon one by one, each after the siblings it refers to.  Scanning
# for the valid paths alone, it dropped a reference to a sibling that was not
# registered yet.
#
# Usage: unrelated-reference.sh [DAEMON] [FIXTURE]
# Runs against DAEMON (default the daemon of this tree); both daemons pass.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${1:-${GOONIX_TEST_DAEMON:-$root/guix-daemon}}
fixture=${2:-$root/.scratch/unrelated-reference}
if test -e "$fixture"; then chmod -R u+rwX "$fixture" 2>/dev/null || true; rm -rf "$fixture"; fi
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
mkdir -p "$fixture/etc" "$fixture/cache"
# The daemon signs build records of the resolved-addressed derivation.
cp "$root/tests/keys/openpgp/signing-key.sec" "$root/tests/keys/openpgp/signing-key.pub" "$fixture/etc/"
chmod 0400 "$fixture/etc/signing-key.sec"
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix" GUIX_CONFIGURATION_DIRECTORY="$fixture/etc"
export XDG_CACHE_HOME="$fixture/cache" GUILE_AUTO_COMPILE=0
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
  "$root/daemon/test/differential/unrelated-reference.scm" | tee "$fixture/client.log"
grep -Fq 'unrelated store paths are no references: PASS' "$fixture/client.log"

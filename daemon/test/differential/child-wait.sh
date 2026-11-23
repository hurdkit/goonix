#!/usr/bin/env bash
# Regression: waiting for a child must not hold a GHC capability.  Compiles the
# daemon's Goonix.Build.Wait (nonblocking waitpid poll) with a probe that forks a
# child sleeping 3s and compares a BLOCKING waitpid (getProcessStatus True) against
# the nonblocking poll while a pure allocating loop runs, +RTS -A1m -N.  PASS when
# the poll keeps the loop running (well under the sleep) and the blocking wait is
# shown to freeze it.  No daemon or store fixture needed; runs in regressions.sh.
#
# Usage: child-wait.sh [TREE]
set -euo pipefail
root=${1:-$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)}
here="$root/daemon/test/differential"
. "$root/daemon/test/lib.sh"
command -v ghc >/dev/null 2>&1 || { echo "no ghc"; exit 2; }
out=$(mktemp -d /tmp/child-wait.XXXXXX)
trap 'rm -rf "$out"' EXIT
goonix_run_capped ghc -threaded -rtsopts -O0 -XGHC2024 -XBangPatterns \
  -outputdir "$out/obj" -o "$out/child-wait" \
  -i"$root/daemon/src" "$here/child-wait.hs"
goonix_run_capped "$out/child-wait" +RTS -A1m -N -RTS
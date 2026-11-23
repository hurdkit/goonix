#!/usr/bin/env bash
# Regression: waitProcessStatusNonBlocking must not accumulate memory per poll.
# Before the fix `go` recursed INSIDE alloca's body, so every 10ms poll's pinned
# status buffer + stack frame stayed alive until the child exited (~360,000 per hour
# of build).  After the fix alloca is OUTSIDE the loop (one buffer, tail call).
# Compiles the daemon's Wait.hs with a probe that waits on a child sleeping 12s (~1200
# polls), sampling gcdetails_live_bytes after a major GC at t=2s and t=11s, under a
# tight stack (-K64k) and GC stats (-T).  Before the fix live bytes GROW per poll
# (calibrated ~7 KB/s, ~60 KB over the window); after the fix only the sampler's small
# baseline (< ~10 KB) and the exit code is reaped.  No daemon or store needed; runs in
# regressions.sh.
#
# Usage: wait-stack.sh [TREE]
set -euo pipefail
root=${1:-$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)}
here="$root/daemon/test/differential"
. "$root/daemon/test/lib.sh"
command -v ghc >/dev/null 2>&1 || { echo "no ghc"; exit 2; }
out=$(mktemp -d /tmp/wait-stack.XXXXXX)
trap 'rm -rf "$out"' EXIT
goonix_run_capped ghc -threaded -rtsopts -O2 -XGHC2024 -XBangPatterns \
  -outputdir "$out/obj" -o "$out/wait-stack" \
  -i"$root/daemon/src" "$here/wait-stack.hs"
# -K64k: tight stack (per-poll frame growth overflows on RTSes that do not reclaim).
# -T: GC stats (gcdetails_live_bytes).  The child sleeps 8s; allow 60s.
GOONIX_TEST_TIMEOUT=60 goonix_run_capped "$out/wait-stack" +RTS -K64k -T -N -RTS
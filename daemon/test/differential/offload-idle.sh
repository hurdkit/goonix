#!/usr/bin/env bash
# Regression: the offload hook reply read (receiveLine) must wait through the IO
# manager, not a raw blocking hGetLine.  Compiles the daemon sources with a probe
# that runs receiveLine on a silent socketpair while a pure allocating loop runs,
# +RTS -A1m -N.  PASS when the loop finishes well under the silence and receiveLine
# survives (parked, then reads the line).  No daemon/store needed; regressions.sh.
#
# Usage: offload-idle.sh [TREE]
set -euo pipefail
root=${1:-$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)}
here="$root/daemon/test/differential"
. "$root/daemon/test/lib.sh"
command -v ghc >/dev/null 2>&1 || { echo "no ghc"; exit 2; }
out=$(mktemp -d /tmp/offload-idle.XXXXXX)
trap 'rm -rf "$out"' EXIT
sources=$(find "$root/daemon/src" -name '*.hs' -print)
goonix_run_capped ghc -threaded -rtsopts -O0 -XGHC2024 -XBangPatterns -XOverloadedStrings \
  -outputdir "$out/obj" -o "$out/offload-idle" \
  -i"$root/daemon/src" "$here/offload-idle.hs" $sources \
  "$root/daemon/cbits/files.c" "$root/daemon/cbits/helpers.c" \
  "$root/daemon/cbits/logs.c" "$root/daemon/cbits/sockets.c" \
  -lgcrypt -lsqlite3 -lz -lbz2
goonix_run_capped "$out/offload-idle" +RTS -A1m -N -RTS
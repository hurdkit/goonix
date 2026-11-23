#!/usr/bin/env bash
# Regression (reviewer point 1): a hook that closes its output before replying must
# make requestOffload RAISE within a bounded time, not spin forever flooding the
# client with newlines.  Compiles the daemon sources with a probe over a pipe whose
# write end is closed (EOF), +RTS -A1m -N.  FAILS before the fix (receiveLine
# returned "" at EOF -> replyLine endless loop), PASSES after (receiveLine throws).
# No daemon/store needed; regressions.sh.
#
# Usage: offload-eof.sh [TREE]
set -euo pipefail
root=${1:-$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)}
here="$root/daemon/test/differential"
. "$root/daemon/test/lib.sh"
command -v ghc >/dev/null 2>&1 || { echo "no ghc"; exit 2; }
out=$(mktemp -d /tmp/offload-eof.XXXXXX)
trap 'rm -rf "$out"' EXIT
sources=$(find "$root/daemon/src" -name '*.hs' -print)
goonix_run_capped ghc -threaded -rtsopts -O0 -XGHC2024 -XBangPatterns -XOverloadedStrings \
  -outputdir "$out/obj" -o "$out/offload-eof" \
  -i"$root/daemon/src" "$here/offload-eof.hs" $sources \
  "$root/daemon/cbits/files.c" "$root/daemon/cbits/helpers.c" \
  "$root/daemon/cbits/logs.c" "$root/daemon/cbits/sockets.c" \
  -lgcrypt -lsqlite3 -lz -lbz2
goonix_run_capped "$out/offload-eof" +RTS -A1m -N -RTS
#!/usr/bin/env bash
# Regression: an idle client (sends nothing) must not freeze the daemon's other
# threads.  Compiles the daemon's own Socket.hs with a probe that reads one end of
# an AF_UNIX socketpair while the peer stays silent and a third thread runs a pure
# allocating loop, +RTS -A1m -N.  PASS when the loop finishes well under the
# client's silence; FAIL when readSocket is a raw blocking read that holds its
# capability and freezes GC.  No daemon, store, or extra package is needed, so this
# runs in regressions.sh (through the dev shell, which has ghc).
#
# Usage: socket-idle.sh [TREE]
set -euo pipefail
root=${1:-$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)}
here="$root/daemon/test/differential"
. "$root/daemon/test/lib.sh"
command -v ghc >/dev/null 2>&1 || { echo "no ghc"; exit 2; }
out=$(mktemp -d /tmp/socket-idle.XXXXXX)
trap 'rm -rf "$out"' EXIT
# Socket.hs is self-contained (boot libs + bytestring); the probe uses a raw
# socketpair via ccall, so no network package is required.
goonix_run_capped ghc -threaded -rtsopts -O0 -XGHC2024 -XBangPatterns -XOverloadedStrings \
  -outputdir "$out/obj" -o "$out/socket-idle" \
  -i"$root/daemon/src" "$here/socket-idle.hs" "$root/daemon/cbits/sockets.c"
goonix_run_capped "$out/socket-idle" +RTS -A1m -N -RTS
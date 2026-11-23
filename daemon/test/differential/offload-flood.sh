#!/usr/bin/env bash
# Regression (reviewer point 2): finishOffload must drain ALL of a hook's output and
# return even when the hook writes >64 KiB with pauses (the non-blocking output fd
# hits EAGAIN between bursts).  Compiles the daemon sources with a probe that spawns
# the real offload-flood-helper.sh, accepts, and finishOffload, +RTS -A1m -N.  FAILS
# before the fix (drainFd treated EAGAIN as EOF -> bytes lost / hang), PASSES after.
# No daemon/store needed; regressions.sh.
#
# Usage: offload-flood.sh [TREE]
set -euo pipefail
root=${1:-$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)}
here="$root/daemon/test/differential"
. "$root/daemon/test/lib.sh"
command -v ghc >/dev/null 2>&1 || { echo "no ghc"; exit 2; }
out=$(mktemp -d /tmp/offload-flood.XXXXXX)
trap 'rm -rf "$out"' EXIT
# The helper needs an absolute bash + a working PATH (the daemon spawns it with the
# caller's env, but be safe): wrap it as root-ci-substitute.sh does.
bash_abs=$(command -v bash)
helper="$out/helper.wrapper"
{ printf '#!%s\n' "$bash_abs"; printf 'export PATH=%s\n' "$PATH";
  cat "$here/offload-flood-helper.sh"; } > "$helper"
chmod +x "$helper"
sources=$(find "$root/daemon/src" -name '*.hs' -print)
goonix_run_capped ghc -threaded -rtsopts -O0 -XGHC2024 -XBangPatterns -XOverloadedStrings \
  -outputdir "$out/obj" -o "$out/offload-flood" \
  -i"$root/daemon/src" "$here/offload-flood.hs" $sources \
  "$root/daemon/cbits/files.c" "$root/daemon/cbits/helpers.c" \
  "$root/daemon/cbits/logs.c" "$root/daemon/cbits/sockets.c" \
  -lgcrypt -lsqlite3 -lz -lbz2
goonix_run_capped "$out/offload-flood" "$helper" +RTS -A1m -N -RTS
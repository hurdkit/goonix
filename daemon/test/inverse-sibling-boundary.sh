#!/usr/bin/env bash
# Regression: inverseTree must invert a sibling hash inside the streaming
# retention tail and across a 128 KiB read, not only prefixes of `final`.
# Before the fix a sibling hash ending within 31 bytes of EOF was split across
# chunks and never replaced, so sameContent reported false for identical
# content - a spurious CA collision for multi-output derivations.
# Fails before, passes after.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/goonix-inverse-sibling.XXXXXX")
trap 'find "$tmp" -type d -exec chmod u+rwx {} + 2>/dev/null || true; rm -rf "$tmp"' EXIT
sources=$(find "$here/../src" -name '*.hs' -print)
goonix_run_capped ghc -threaded -O0 -outputdir "$tmp/obj" -o "$tmp/inverse-sibling-boundary" \
  -i"$here/../src" "$here/inverse-sibling-boundary.hs" \
  "$here/../cbits/sockets.c" "$here/../cbits/files.c" "$here/../cbits/helpers.c" "$here/../cbits/logs.c" \
  $sources -lgcrypt -lsqlite3 -lz -lbz2
goonix_run_capped "$tmp/inverse-sibling-boundary" "$tmp/run"
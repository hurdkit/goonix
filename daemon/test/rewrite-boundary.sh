#!/usr/bin/env bash
# Regression: rewriteRegularFile's streaming result must equal the WHOLE-FILE
# result at every offset.  Two defects in the prefix-hold-back loop: a complete
# plain self-reference ending at the emit point loses its last byte and is
# wrongly REJECTED; an opaque occurrence straddling the emit point is split and
# wrongly ACCEPTED.  The oracle is replaceWhole over the whole file.
# Fails before, passes after.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/goonix-rewrite-boundary.XXXXXX")
trap 'find "$tmp" -type d -exec chmod u+rwx {} + 2>/dev/null || true; rm -rf "$tmp"' EXIT
sources=$(find "$here/../src" -name '*.hs' -print)
goonix_run_capped ghc -threaded -O0 -outputdir "$tmp/obj" -o "$tmp/rewrite-boundary" \
  -i"$here/../src" "$here/rewrite-boundary.hs" \
  "$here/../cbits/sockets.c" "$here/../cbits/files.c" "$here/../cbits/helpers.c" "$here/../cbits/logs.c" \
  $sources -lgcrypt -lsqlite3 -lz -lbz2
goonix_run_capped "$tmp/rewrite-boundary" "$tmp/run"
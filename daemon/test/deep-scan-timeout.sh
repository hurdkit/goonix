#!/usr/bin/env bash
# Regression: DeepScan.readDiagnostic must honour goonix-deep-scan-timeout.
# Before the fix the timeout wrapped only lazy hGetContents (returns instantly),
# so a hung helper blocked forever; after the fix the read is forced inside the
# timeout and the helper is killed at the deadline.  Fails before, passes after.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/goonix-deep-scan-timeout.XXXXXX")
trap 'find "$tmp" -type d -exec chmod u+rwx {} + 2>/dev/null || true; rm -rf "$tmp"' EXIT
sources=$(find "$here/../src" -name '*.hs' -print)
goonix_run_capped ghc -threaded -O0 -outputdir "$tmp/obj" -o "$tmp/deep-scan-timeout" \
  -i"$here/../src" "$here/deep-scan-timeout.hs" \
  "$here/../cbits/sockets.c" "$here/../cbits/files.c" "$here/../cbits/helpers.c" "$here/../cbits/logs.c" \
  $sources -lgcrypt -lsqlite3 -lz -lbz2
goonix_run_capped "$tmp/deep-scan-timeout" +RTS -N2
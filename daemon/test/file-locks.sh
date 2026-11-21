#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/goonix-file-locks.XXXXXX")
trap 'find "$tmp" -type d -exec chmod u+rwx {} + 2>/dev/null || true; rm -rf "$tmp"' EXIT
sources=$(find "$here/../src" -name '*.hs' -print)
goonix_run_capped ghc -threaded -O0 -outputdir "$tmp/obj" -o "$tmp/file-locks" \
  -i"$here/../src" "$here/file-locks.hs" "$here/../cbits/files.c" $sources \
  -lgcrypt -lsqlite3 -lz -lbz2
for caps in 1 4; do
  echo "file-locks: -N$caps"
  goonix_run_capped "$tmp/file-locks" "$tmp/store-$caps" +RTS -N"$caps"
done

#!/usr/bin/env bash
# Regression: concurrent makeSymlinkAtomic calls for the SAME link must all
# succeed.  The daemon serves clients in threads of ONE process, so a fixed
# temp name is shared: removeLink deletes another thread's temp, symlink()
# fails EEXIST, or rename() fails ENOENT.  C++ uses link.tmp-<pid>-<rand>.
# Fails before, passes after.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/goonix-symlink-concurrent.XXXXXX")
trap 'find "$tmp" -type d -exec chmod u+rwx {} + 2>/dev/null || true; rm -rf "$tmp"' EXIT
sources=$(find "$here/../src" -name '*.hs' -print)
goonix_run_capped ghc -threaded -O0 -outputdir "$tmp/obj" -o "$tmp/symlink-concurrent" \
  -i"$here/../src" "$here/symlink-concurrent.hs" \
  "$here/../cbits/sockets.c" "$here/../cbits/files.c" "$here/../cbits/helpers.c" "$here/../cbits/logs.c" \
  $sources -lgcrypt -lsqlite3 -lz -lbz2
goonix_run_capped "$tmp/symlink-concurrent" "$tmp/run" +RTS -N4
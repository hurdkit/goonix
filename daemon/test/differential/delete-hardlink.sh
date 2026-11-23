#!/usr/bin/env bash
# Regression: deleteTree must not chmod the file it unlinks (the dedup hardlink
# EACCES race).  Compiles the daemon's own Files.hs (with Nar/Hash/Base32 and
# files.c, linking libgcrypt) with a probe that hard-links an executable file,
# deletes one link with deleteTree, and checks the other link keeps its exec bit.
# FAILS on the pre-fix tree (deleteTree chmods the shared inode to 0o644), PASSES
# after.  No daemon, store fixture, or namespace is needed, so this runs in the
# pre-daemon regressions.sh (through the dev shell, which has ghc + libgcrypt).
#
# Usage: delete-hardlink.sh [TREE]
set -euo pipefail
root=${1:-$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)}
here="$root/daemon/test/differential"
. "$root/daemon/test/lib.sh"
command -v ghc >/dev/null 2>&1 || { echo "no ghc"; exit 2; }
out=$(mktemp -d /tmp/delete-hardlink.XXXXXX)
trap 'rm -rf "$out"' EXIT
# Files.hs pulls Nar -> Hash (libgcrypt).  Link gcrypt as the daemon build does.
gcrypt_libs=$(pkg-config --libs libgcrypt 2>/dev/null || echo "-lgcrypt")
goonix_run_capped ghc -threaded -rtsopts -O0 -XGHC2024 -XBangPatterns -XOverloadedStrings -XStrictData \
  -outputdir "$out/obj" -o "$out/delete-hardlink" \
  -i"$root/daemon/src" "$here/delete-hardlink.hs" "$root/daemon/cbits/files.c" \
  $gcrypt_libs
goonix_run_capped "$out/delete-hardlink"
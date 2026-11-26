#!/usr/bin/env bash
# Regression: `guix authenticate' requests must return while a build is running.
# Compiles the daemon sources with a probe that keeps one thread polling, as the
# builder wait does, and sends requests to a stand-in helper that, like the real
# one, answers and then reads until its input ends.  FAILS before the fix (the
# daemon waited for the helper with its input open, so only a garbage collection
# ended the wait), PASSES after.  No daemon or store needed; regressions.sh.
#
# Usage: authenticate-busy.sh [TREE]
set -euo pipefail
root=${1:-$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)}
here="$root/daemon/test/differential"
. "$root/daemon/test/lib.sh"
command -v ghc >/dev/null 2>&1 || { echo "no ghc"; exit 2; }
out=$(mktemp -d /tmp/authenticate-busy.XXXXXX)
trap 'rm -rf "$out"' EXIT
cat > "$out/guix" <<EOF
#!/bin/sh
# A stand-in for \`guix authenticate': one reply, then wait for the end of input.
test "\$1" = authenticate || exit 64
echo \$\$ > "$out/helper.pid"
IFS= read -r request || exit 65
printf '0 4:abcd'
exec cat > /dev/null
EOF
chmod 755 "$out/guix"
sources=$(find "$root/daemon/src" -name '*.hs' -print)
goonix_run_capped ghc -threaded -rtsopts -O0 -XGHC2024 -XBangPatterns -XOverloadedStrings \
  -outputdir "$out/obj" -o "$out/authenticate-busy" \
  -i"$root/daemon/src" "$here/authenticate-busy.hs" $sources \
  "$root/daemon/cbits/files.c" "$root/daemon/cbits/helpers.c" \
  "$root/daemon/cbits/logs.c" "$root/daemon/cbits/sockets.c" \
  -lgcrypt -lsqlite3 -lz -lbz2
GUIX="$out/guix" goonix_run_capped "$out/authenticate-busy" "$out" +RTS -N -RTS

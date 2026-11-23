#!/usr/bin/env bash
# CA finalisation against an unregistered leftover: build
# daemon/test/ca-leftover/Main.hs against the tree's daemon modules and run it
# in a scratch store.  Uses the daemon's GHC flags (from the make recipe) but a
# separate outputdir so it does not disturb the daemon build.
#
# Usage: daemon/test/ca-leftover.sh [scratch-directory]
# The scratch directory is created if absent and left in place for inspection.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root" || exit 1
scratch=${1:-$(mktemp -d /tmp/ca-leftover-XXXXXX)}
mkdir -p "$scratch" || exit 1
nix develop .#default -c bash -s "$root" "$scratch" <<'INNER'
set -uo pipefail
root=$1; scratch=$2
cd "$root" || exit 1
GHC=$PWD/hs0-tools/ghc/bin/ghc
# Take the ghc --make line from the daemon recipe, strip the recipe prefix, drop
# -outputdir/-o and the daemon's own sources (we supply our own Main.hs).
line=$(make -B -n guix-daemon 2>/dev/null | grep -m1 -- '--make')
flags=$(printf '%s\n' "$line" | sed -e 's/.*--make //' \
  -e 's/-outputdir [^ ]*//' -e 's/-o [^ ]*//' \
  -e 's#[^ ]*daemon/cbits/[a-z]*\.c##g' -e 's#[^ ]*daemon/app/Main\.hs##g' \
  -e 's/; mv .*//' -e 's/\\$//')
test -n "$flags" || { echo "CA_LEFTOVER_NO_FLAGS"; exit 1; }
"$GHC" --make $flags -outputdir "$scratch/build" -o "$scratch/ca-leftover.tmp" \
  daemon/cbits/sockets.c daemon/cbits/files.c daemon/cbits/helpers.c daemon/cbits/logs.c \
  daemon/test/ca-leftover/Main.hs > "$scratch/build.log" 2>&1
rc=$?
if test "$rc" -ne 0; then
  echo "CA_LEFTOVER_BUILD_RC=$rc"
  tail -25 "$scratch/build.log"
  exit "$rc"
fi
mv "$scratch/ca-leftover.tmp" "$scratch/ca-leftover"
"$scratch/ca-leftover" "$scratch/run"
echo "CA_LEFTOVER_RC=$?"
INNER
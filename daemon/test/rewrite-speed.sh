#!/usr/bin/env bash
# Time the forward rewrite on ONE large regular file with NO occurrence of FROM,
# in Haskell (rewriteTree) and in C++ (checkRewriteForTest), on the same bytes.
# This measures the SEARCH cost: breakOn/occurrence step one byte at a time and
# replaceWhole runs one such search per 8-byte fragment and per encoding.
#
# Usage: daemon/test/rewrite-speed.sh [scratch-directory] [bytes]
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root" || exit 1
scratch=${1:-$(mktemp -d /tmp/ca-rewrite-speed-XXXXXX)}
bytes=${2:-8388608}
mkdir -p "$scratch" || exit 1
nix develop .#default -c bash -s "$root" "$scratch" "$bytes" <<'INNER'
set -uo pipefail
root=$1; scratch=$2; bytes=$3
cd "$root" || exit 1

# --- C++ side ---
CXXOBJS=$(ls nix/libstore/libstore_a-*.o nix/libutil/libutil_a-*.o 2>/dev/null | grep -v 'libstore_a-ca.o' | tr '\n' ' ')
test -n "$CXXOBJS" || { echo NO_CXX_OBJECTS; exit 2; }
GCL=$(grep -m1 '^LIBGCRYPT_LDFLAGS = ' Makefile | sed 's/^[^=]*= //')
GCLIB=$(grep -m1 '^LIBGCRYPT_LIBS = ' Makefile | sed 's/^[^=]*= //')
SQL=$(grep -m1 '^SQLITE3_LIBS = ' Makefile | sed 's/^[^=]*= //')
g++ -std=c++20 -O1 -DHAVE_CONFIG_H -I. -I./nix -I./nix/libutil -I./nix/libstore -fPIC \
  -c nix/libstore/ca.cc -o "$scratch/ca.o" 2>"$scratch/ca-compile.log" || {
    echo CA_COMPILE_FAIL; tail -10 "$scratch/ca-compile.log"; exit 1; }
g++ -std=c++20 -O1 -DHAVE_CONFIG_H -I. -I./nix -I./nix/libutil -I./nix/libstore \
  -c nix/libstore/rewrite-speed-probe.cc -o "$scratch/speed.o" 2>"$scratch/cxx-compile.log" || {
    echo CXX_COMPILE_FAIL; tail -10 "$scratch/cxx-compile.log"; exit 1; }
g++ -std=c++20 -O1 -o "$scratch/cxx-speed" "$scratch/speed.o" "$scratch/ca.o" $CXXOBJS \
  -lz -lbz2 $SQL $GCL $GCLIB -pthread 2>"$scratch/cxx-link.log" || {
    echo CXX_LINK_FAIL; tail -10 "$scratch/cxx-link.log"; exit 1; }
mkdir -p "$scratch/cxx-run"
"$scratch/cxx-speed" "$scratch/cxx-run" "$bytes"
echo "CXX_SPEED_RC=$?"
chmod -R u+w "$scratch/cxx-run" 2>/dev/null

# --- Haskell side ---
GHC=$PWD/hs0-tools/ghc/bin/ghc
line=$(make -B -n guix-daemon 2>/dev/null | grep -m1 -- '--make')
flags=$(printf '%s\n' "$line" | sed -e 's/.*--make //' \
  -e 's/-outputdir [^ ]*//' -e 's/-o [^ ]*//' \
  -e 's#[^ ]*daemon/cbits/[a-z]*\.c##g' -e 's#[^ ]*daemon/app/Main\.hs##g' \
  -e 's/; mv .*//' -e 's/\\$//')
test -n "$flags" || { echo NO_GHC_FLAGS; exit 1; }
"$GHC" --make $flags -outputdir "$scratch/hs-build" -o "$scratch/hs-speed.tmp" \
  daemon/cbits/sockets.c daemon/cbits/files.c daemon/cbits/helpers.c daemon/cbits/logs.c \
  daemon/test/rewrite-speed/Main.hs > "$scratch/hs-build.log" 2>&1 || {
    echo HS_BUILD_FAIL; tail -20 "$scratch/hs-build.log"; exit 1; }
mv "$scratch/hs-speed.tmp" "$scratch/hs-speed"
mkdir -p "$scratch/hs-run"
"$scratch/hs-speed" "$scratch/hs-run" "$bytes"
echo "HS_SPEED_RC=$?"
chmod -R u+w "$scratch/hs-run" 2>/dev/null
INNER
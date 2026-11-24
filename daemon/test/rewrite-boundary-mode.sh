#!/usr/bin/env bash
# C++/HS parity of the FORWARD rewrite at the read boundaries.
#
# The invariant: rewriteRegularFile's streaming result must equal the WHOLE-FILE
# result at any offset and for any read split.  Both sides were fixed (HS
# 73af00cd431, C++ e222d92d6f4).  The C++ probe drives checkRewriteForTest and
# uses replaceWholeForTest as the oracle; the Haskell side drives rewriteTree and
# uses replaceWhole.  Each case reports the verdict, a digest of the accepted
# bytes, and whether that side agrees with its OWN whole-file oracle.
#
# Usage: daemon/test/rewrite-boundary-mode.sh [scratch-directory]
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root" || exit 1
scratch=${1:-$(mktemp -d /tmp/ca-rewrite-boundary-mode-XXXXXX)}
mkdir -p "$scratch" || exit 1
nix develop .#default -c bash -s "$root" "$scratch" <<'INNER'
set -uo pipefail
root=$1; scratch=$2
cd "$root" || exit 1

LABELS='^(plain-eof-|plain-read-|utf32-|utf16-|frag0-|frag12-|frag-early|frag-third-read|frag-final-tail|plain-only|no-reference)'

# --- C++ side ---
CXXOBJS=$(ls nix/libstore/libstore_a-*.o nix/libutil/libutil_a-*.o 2>/dev/null | grep -v 'libstore_a-ca.o' | tr '\n' ' ')
test -n "$CXXOBJS" || { echo "NO_CXX_OBJECTS: build the C++ daemon objects first" >&2; exit 2; }
GCL=$(grep -m1 '^LIBGCRYPT_LDFLAGS = ' Makefile | sed 's/^[^=]*= //')
GCLIB=$(grep -m1 '^LIBGCRYPT_LIBS = ' Makefile | sed 's/^[^=]*= //')
SQL=$(grep -m1 '^SQLITE3_LIBS = ' Makefile | sed 's/^[^=]*= //')
g++ -std=c++20 -O1 -DHAVE_CONFIG_H -I. -I./nix -I./nix/libutil -I./nix/libstore -fPIC \
  -c nix/libstore/ca.cc -o "$scratch/ca.o" 2>"$scratch/ca-compile.log" || {
    echo CA_COMPILE_FAIL; tail -15 "$scratch/ca-compile.log"; exit 1; }
g++ -std=c++20 -O1 -DHAVE_CONFIG_H -I. -I./nix -I./nix/libutil -I./nix/libstore \
  -c nix/libstore/rewrite-boundary-probe.cc -o "$scratch/probe.o" 2>"$scratch/cxx-compile.log" || {
    echo CXX_COMPILE_FAIL; tail -15 "$scratch/cxx-compile.log"; exit 1; }
g++ -std=c++20 -O1 -o "$scratch/cxx-probe" "$scratch/probe.o" "$scratch/ca.o" $CXXOBJS \
  -lz -lbz2 $SQL $GCL $GCLIB -pthread 2>"$scratch/cxx-link.log" || {
    echo CXX_LINK_FAIL; tail -15 "$scratch/cxx-link.log"; exit 1; }
mkdir -p "$scratch/cxx-run"
"$scratch/cxx-probe" "$scratch/cxx-run" 2>/dev/null | grep -E "$LABELS" > "$scratch/cxx.txt"
echo "CXX_PROBE_RC=$?"
chmod -R u+w "$scratch/cxx-run" 2>/dev/null

# --- Haskell side ---
GHC=$PWD/hs0-tools/ghc/bin/ghc
line=$(make -B -n guix-daemon 2>/dev/null | grep -m1 -- '--make')
flags=$(printf '%s\n' "$line" | sed -e 's/.*--make //' \
  -e 's/-outputdir [^ ]*//' -e 's/-o [^ ]*//' \
  -e 's#[^ ]*daemon/cbits/[a-z]*\.c##g' -e 's#[^ ]*daemon/app/Main\.hs##g' \
  -e 's/; mv .*//' -e 's/\\$//')
test -n "$flags" || { echo NO_GHC_FLAGS; exit 1; }
"$GHC" --make $flags -outputdir "$scratch/hs-build" -o "$scratch/hs-probe.tmp" \
  daemon/cbits/sockets.c daemon/cbits/files.c daemon/cbits/helpers.c daemon/cbits/logs.c \
  daemon/test/rewrite-boundary-mode/Main.hs > "$scratch/hs-build.log" 2>&1 || {
    echo HS_BUILD_FAIL; tail -20 "$scratch/hs-build.log"; exit 1; }
mv "$scratch/hs-probe.tmp" "$scratch/hs-probe"
mkdir -p "$scratch/hs-run"
"$scratch/hs-probe" "$scratch/hs-run" 2>/dev/null | grep -E "$LABELS" > "$scratch/hs.txt"
echo "HS_PROBE_RC=$?"
chmod -R u+w "$scratch/hs-run" 2>/dev/null

echo "=== C++ (reference) ==="; cat "$scratch/cxx.txt"
echo "=== Haskell ==="; cat "$scratch/hs.txt"

# A probe that produced NOTHING must not read as agreement.
for f in cxx hs; do
  if ! test -s "$scratch/$f.txt"; then
    echo "EMPTY_PROBE_OUTPUT: the $f probe produced no result lines"
    test -f "$scratch/$f-compile.log" && tail -5 "$scratch/$f-compile.log"
    test -f "$scratch/$f-build.log" && tail -5 "$scratch/$f-build.log"
    exit 1
  fi
done

# Both probes already normalise the file name to <file> and strip the Haskell
# exception wrapper, so the message text and the byte OFFSET are compared
# verbatim - that is the point of this probe.
if diff -u "$scratch/cxx.txt" "$scratch/hs.txt" > "$scratch/diff.txt" 2>&1; then
  echo "REWRITE_BOUNDARY_MODE_MATCH: Haskell matches C++ on every fixture"
  exit 0
fi
echo "REWRITE_BOUNDARY_MODE_DIFFER:"
cat "$scratch/diff.txt"
exit 1
INNER

#!/usr/bin/env bash
# Compare materialiseGoonixFiles' ACCEPT/REJECT verdict for embedded builder-file
# names against the REAL C++ function (build-ca.cc), driven directly.
#
# Measured, not modelled: an earlier hypothesis said C++ std::getline drops the
# trailing empty field so "a/" would be ACCEPTED where the Haskell split rejects
# it.  Driving the real function shows the VERDICT agrees on all 21 names: C++
# passes the name check for "a/" and then fails in writeFile ("Is a directory"),
# so both sides refuse it.  What differs is the MESSAGE and a side effect, which
# daemon/DIFFERENCES.md records; this probe pins the verdict, which is the
# security-relevant part (a traversal name must never be written).
#
# Usage: embedded-mode.sh [scratch-directory]
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root" || exit 1
scratch=${1:-$(mktemp -d /tmp/ca-embedded-mode-XXXXXX)}
mkdir -p "$scratch" || exit 1
nix develop .#default -c bash -s "$root" "$scratch" <<'INNER'
set -uo pipefail
root=$1; scratch=$2
cd "$root" || exit 1

GCL=$(grep -m1 '^LIBGCRYPT_LDFLAGS = ' Makefile | sed 's/^[^=]*= //')
GCLIB=$(grep -m1 '^LIBGCRYPT_LIBS = ' Makefile | sed 's/^[^=]*= //')
SQL=$(grep -m1 '^SQLITE3_LIBS = ' Makefile | sed 's/^[^=]*= //')

# --- C++ side ---
# build-ca.o needs ca.o's symbols (addressingOf, tokenPath, ...), so ca.cc is
# compiled and linked here rather than excluded as the ca-only probes do.
g++ -std=c++20 -O1 -DHAVE_CONFIG_H -I. -I./nix -I./nix/libutil -I./nix/libstore -fPIC \
  -c nix/libstore/ca.cc -o "$scratch/ca.o" 2>"$scratch/ca-compile.log" || {
    echo CA_COMPILE_FAIL; tail -10 "$scratch/ca-compile.log"; exit 1; }
CXXOBJS=$(ls nix/libstore/libstore_a-*.o nix/libutil/libutil_a-*.o 2>/dev/null | grep -v 'libstore_a-ca.o' | tr '\n' ' ')
test -n "$CXXOBJS" || { echo NO_CXX_OBJECTS; exit 2; }
g++ -std=c++20 -O1 -DHAVE_CONFIG_H -I. -I./nix -I./nix/libutil -I./nix/libstore \
  -c nix/libstore/embedded-probe.cc -o "$scratch/probe.o" 2>"$scratch/cxx-compile.log" || {
    echo CXX_COMPILE_FAIL; tail -10 "$scratch/cxx-compile.log"; exit 1; }
g++ -std=c++20 -O1 -o "$scratch/cxx-probe" "$scratch/probe.o" "$scratch/ca.o" $CXXOBJS \
  -lz -lbz2 $SQL $GCL $GCLIB -pthread 2>"$scratch/cxx-link.log" || {
    echo CXX_LINK_FAIL; tail -10 "$scratch/cxx-link.log"; exit 1; }
"$scratch/cxx-probe" "$scratch/cxx-run" > "$scratch/cxx.raw" 2>/dev/null
echo "CXX_PROBE_RC=$?"

# --- Haskell side ---
line=$(make -B -n guix-daemon 2>/dev/null | grep -m1 -- '--make')
flags=$(printf '%s\n' "$line" | sed -e 's/.*--make //' \
  -e 's/-outputdir [^ ]*//' -e 's/-o [^ ]*//' \
  -e 's#[^ ]*daemon/cbits/[a-z]*\.c##g' -e 's#[^ ]*daemon/app/Main\.hs##g' \
  -e 's/; mv .*//' -e 's/\\$//')
test -n "$flags" || { echo NO_GHC_FLAGS; exit 1; }
./hs0-tools/ghc/bin/ghc --make $flags -outputdir "$scratch/hs-build" -o "$scratch/hs-probe.tmp" \
  daemon/cbits/sockets.c daemon/cbits/files.c daemon/cbits/helpers.c daemon/cbits/logs.c \
  daemon/test/embedded-mode/Main.hs > "$scratch/hs-build.log" 2>&1 || {
    echo HS_BUILD_FAIL; tail -20 "$scratch/hs-build.log"; exit 1; }
mv "$scratch/hs-probe.tmp" "$scratch/hs-probe"
"$scratch/hs-probe" "$scratch/hs-run" > "$scratch/hs.raw" 2>/dev/null
echo "HS_PROBE_RC=$?"

# Compare the VERDICT (OK vs ERROR), not the message text: the wording of the
# trailing-slash refusal is a recorded adaptation.
sed -E 's/^(name="[^"]*") (OK|ERROR).*/\1 \2/' "$scratch/cxx.raw" > "$scratch/cxx.txt"
sed -E 's/^(name="[^"]*") (OK|ERROR).*/\1 \2/' "$scratch/hs.raw" > "$scratch/hs.txt"

if test ! -s "$scratch/cxx.txt" || test ! -s "$scratch/hs.txt"; then
  echo "EMPTY_PROBE_OUTPUT cxx=$(wc -l <"$scratch/cxx.txt") hs=$(wc -l <"$scratch/hs.txt")"
  exit 1
fi
# Every name must have reported on both sides, and the OK set must be non-empty
# (a probe that rejects everything would otherwise "agree").
for lane in cxx hs; do
  n=$(grep -c '^name=' "$scratch/$lane.txt")
  test "$n" -eq 21 || { echo "MISSING_CASES $lane $n"; exit 1; }
  grep -q ' OK$' "$scratch/$lane.txt" || { echo "NO_ACCEPTED_CASE $lane"; exit 1; }
done

if diff -u "$scratch/cxx.txt" "$scratch/hs.txt" > "$scratch/diff.txt"; then
  echo "EMBEDDED_MODE_MATCH: Haskell accepts and refuses exactly the C++ names"
  exit 0
fi
echo "EMBEDDED_MODE_DIFFER"
cat "$scratch/diff.txt"
exit 1
INNER
#!/usr/bin/env bash
# Compare the Haskell contentOutputOrder with the REAL C++ one.
#
# C++ contentOutputOrder (nix/libstore/ca.cc) walks the sibling outputs in
# std::map order (by PATH, not by output name), visits a referenced sibling
# first, and emits post-order.  This runs the same fixtures through both and
# diffs the emitted sequence, so the comparison is against measured C++
# behaviour rather than a reading of the code.
#
# contentOutputOrder is already declared in ca.hh: the C++ probe calls the
# shipped function, no new hook is needed.
#
# Usage: daemon/test/order-mode.sh [scratch-directory]
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root" || exit 1
scratch=${1:-$(mktemp -d /tmp/ca-order-mode-XXXXXX)}
mkdir -p "$scratch" || exit 1
nix develop .#default -c bash -s "$root" "$scratch" <<'INNER'
set -uo pipefail
root=$1; scratch=$2
cd "$root" || exit 1

LABELS='^(single|out-uses-lib|lib-uses-out|chain|diamond|independent|cycle|self-ref|chroot|non-sibling-ref|missing-out|symlink-ref) '

# --- C++ side: compile + link the probe against the tree's C++ objects ---
CXXOBJS=$(ls nix/libstore/libstore_a-*.o nix/libutil/libutil_a-*.o 2>/dev/null | grep -v 'libstore_a-ca.o' | tr '\n' ' ')
if test -z "$CXXOBJS"; then
  echo "NO_CXX_OBJECTS: configure/build the C++ daemon objects first" >&2
  exit 2
fi
GCL=$(grep -m1 '^LIBGCRYPT_LDFLAGS = ' Makefile | sed 's/^[^=]*= //')
GCLIB=$(grep -m1 '^LIBGCRYPT_LIBS = ' Makefile | sed 's/^[^=]*= //')
SQL=$(grep -m1 '^SQLITE3_LIBS = ' Makefile | sed 's/^[^=]*= //')
g++ -std=c++20 -O1 -DHAVE_CONFIG_H -I. -I./nix -I./nix/libutil -I./nix/libstore -fPIC \
  -c nix/libstore/ca.cc -o "$scratch/ca.o" 2>"$scratch/ca-compile.log" || {
    echo CA_COMPILE_FAIL; tail -15 "$scratch/ca-compile.log"; exit 1; }
g++ -std=c++20 -O1 -DHAVE_CONFIG_H -I. -I./nix -I./nix/libutil -I./nix/libstore \
  -c nix/libstore/order-probe.cc -o "$scratch/probe.o" 2>"$scratch/cxx-compile.log" || {
    echo CXX_COMPILE_FAIL; tail -15 "$scratch/cxx-compile.log"; exit 1; }
g++ -std=c++20 -O1 -o "$scratch/cxx-probe" "$scratch/probe.o" "$scratch/ca.o" $CXXOBJS \
  -lz -lbz2 $SQL $GCL $GCLIB -pthread 2>"$scratch/cxx-link.log" || {
    echo CXX_LINK_FAIL; tail -15 "$scratch/cxx-link.log"; exit 1; }
mkdir -p "$scratch/cxx-run"
"$scratch/cxx-probe" "$scratch/cxx-run" 2>/dev/null | grep -E "$LABELS" > "$scratch/cxx.txt"
echo "CXX_PROBE_RC=$?"
chmod -R u+w "$scratch/cxx-run" 2>/dev/null

# --- Haskell side: build against the daemon modules ---
GHC=$PWD/hs0-tools/ghc/bin/ghc
line=$(make -B -n guix-daemon 2>/dev/null | grep -m1 -- '--make')
flags=$(printf '%s\n' "$line" | sed -e 's/.*--make //' \
  -e 's/-outputdir [^ ]*//' -e 's/-o [^ ]*//' \
  -e 's#[^ ]*daemon/cbits/[a-z]*\.c##g' -e 's#[^ ]*daemon/app/Main\.hs##g' \
  -e 's/; mv .*//' -e 's/\\$//')
test -n "$flags" || { echo NO_GHC_FLAGS; exit 1; }
"$GHC" --make $flags -outputdir "$scratch/hs-build" -o "$scratch/hs-probe.tmp" \
  daemon/cbits/sockets.c daemon/cbits/files.c daemon/cbits/helpers.c daemon/cbits/logs.c \
  daemon/test/order-mode/Main.hs > "$scratch/hs-build.log" 2>&1 || {
    echo HS_BUILD_FAIL; tail -20 "$scratch/hs-build.log"; exit 1; }
mv "$scratch/hs-probe.tmp" "$scratch/hs-probe"
mkdir -p "$scratch/hs-run"
"$scratch/hs-probe" "$scratch/hs-run" 2>/dev/null | grep -E "$LABELS" > "$scratch/hs.txt"
echo "HS_PROBE_RC=$?"
chmod -R u+w "$scratch/hs-run" 2>/dev/null

echo "=== C++ (reference) ==="; cat "$scratch/cxx.txt"
echo "=== Haskell ==="; cat "$scratch/hs.txt"

# A probe that produced NOTHING must not read as agreement: two empty files
# diff equal.  Require both sides to have produced their expected result lines.
for f in cxx hs; do
  if ! test -s "$scratch/$f.txt"; then
    echo "EMPTY_PROBE_OUTPUT: the $f probe produced no result lines"
    test -f "$scratch/$f-compile.log" && tail -5 "$scratch/$f-compile.log"
    test -f "$scratch/$f-build.log" && tail -5 "$scratch/$f-build.log"
    exit 1
  fi
done

# Normalise the scratch prefix and the two libraries' error PROSE.  The
# comparison is on the emitted ORDER and on WHETHER a fixture was refused, not
# on how each runtime spells its exception: C++ says "getting attributes of
# path `P': No such file or directory", Haskell says "P: getSymbolicLinkStatus:
# does not exist (...)".  Both are the same refusal of the same missing path.
# A refusal is reduced to "threw: <class>" plus the path it names, so a real
# behavioural difference (an order that should have been refused, or vice
# versa) still shows up as a diff.
for f in cxx hs; do
  sed -e "s|$scratch/$f-run|SCRATCH|g" "$scratch/$f.txt" \
  | sed -e 's|threw: user error (\(.*\))$|threw: \1|' \
        -e 's|threw: CaError {caErrorMessage = "\(.*\)"}$|threw: \1|' \
        -e 's|threw: StoreError {storeErrorMessage = "\(.*\)".*}$|threw: \1|' \
        -e "s|threw: getting attributes of path \`\(.*\)': No such file or directory|threw: missing-path \1|" \
        -e 's|threw: \(.*\): getSymbolicLinkStatus: does not exist (No such file or directory)|threw: missing-path \1|' \
        -e 's|threw: \(.*\): getSymbolicLinkStatus: does not exist (No such file or directory)$|threw: missing-path \1|' \
  > "$scratch/$f-norm.txt"
done
if diff -u "$scratch/cxx-norm.txt" "$scratch/hs-norm.txt" > "$scratch/diff.txt" 2>&1; then
  echo "ORDER_MODE_MATCH: Haskell matches C++ on every fixture"
  exit 0
fi
echo "ORDER_MODE_DIFFER:"
cat "$scratch/diff.txt"
exit 1
INNER
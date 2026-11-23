#!/usr/bin/env bash
# Compare the Haskell rewriteTree's mode handling with the REAL C++ one.
#
# C++ rewriteRegularFile (nix/libstore/ca.cc) makes the original READABLE only if
# it is not, and never clears a bit; the Haskell port used to chmod 0600
# unconditionally.  This runs the same fixtures through both and diffs the
# resulting modes, so the comparison is against measured C++ behaviour.
#
# The C++ side links nix/libstore/delete-probe.cc against the C++ objects
# already in the tree (libstore_a-*.o, libutil_a-*.o); the Haskell side builds
# daemon/test/delete-mode/Main.hs against the daemon modules.
#
# Usage: daemon/test/rewrite-mode.sh [scratch-directory]
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root" || exit 1
scratch=${1:-$(mktemp -d /tmp/ca-delete-mode-XXXXXX)}
mkdir -p "$scratch" || exit 1
nix develop .#default -c bash -s "$root" "$scratch" <<'INNER'
set -uo pipefail
root=$1; scratch=$2
cd "$root" || exit 1

# --- C++ side: compile + link the probe against the tree's C++ objects ---
CXXOBJS=$(ls nix/libstore/libstore_a-*.o nix/libutil/libutil_a-*.o 2>/dev/null | tr '\n' ' ')
if test -z "$CXXOBJS"; then
  echo "NO_CXX_OBJECTS: configure/build the C++ daemon objects first" >&2
  exit 2
fi
GCL=$(grep -m1 '^LIBGCRYPT_LDFLAGS = ' Makefile | sed 's/^[^=]*= //')
GCLIB=$(grep -m1 '^LIBGCRYPT_LIBS = ' Makefile | sed 's/^[^=]*= //')
SQL=$(grep -m1 '^SQLITE3_LIBS = ' Makefile | sed 's/^[^=]*= //')
g++ -std=c++20 -O1 -DHAVE_CONFIG_H -I. -I./nix -I./nix/libutil -I./nix/libstore \
  -c nix/libstore/delete-probe.cc -o "$scratch/probe.o" 2>"$scratch/cxx-compile.log" || {
    echo CXX_COMPILE_FAIL; tail -15 "$scratch/cxx-compile.log"; exit 1; }
g++ -std=c++20 -O1 -o "$scratch/cxx-probe" "$scratch/probe.o" $CXXOBJS \
  -lz -lbz2 $SQL $GCL $GCLIB -pthread 2>"$scratch/cxx-link.log" || {
    echo CXX_LINK_FAIL; tail -15 "$scratch/cxx-link.log"; exit 1; }
mkdir -p "$scratch/cxx-run"
# Only the fixture result lines: C++ logs progress to stderr.
"$scratch/cxx-probe" "$scratch/cxx-run" 2>/dev/null | grep -E "^(delete-hardlink|delete-readonly-parent|delete-nested|delete-symlink) " > "$scratch/cxx.txt"
echo "CXX_PROBE_RC=$?"
chmod -R u+w "$scratch/cxx-run" 2>/dev/null

# --- Haskell side: build against the daemon modules (ca0-run pattern) ---
GHC=$PWD/hs0-tools/ghc/bin/ghc
line=$(make -B -n guix-daemon 2>/dev/null | grep -m1 -- '--make')
flags=$(printf '%s\n' "$line" | sed -e 's/.*--make //' \
  -e 's/-outputdir [^ ]*//' -e 's/-o [^ ]*//' \
  -e 's#[^ ]*daemon/cbits/[a-z]*\.c##g' -e 's#[^ ]*daemon/app/Main\.hs##g' \
  -e 's/; mv .*//' -e 's/\\$//')
test -n "$flags" || { echo NO_GHC_FLAGS; exit 1; }
"$GHC" --make $flags -outputdir "$scratch/hs-build" -o "$scratch/hs-probe.tmp" \
  daemon/cbits/sockets.c daemon/cbits/files.c daemon/cbits/helpers.c daemon/cbits/logs.c \
  daemon/test/delete-mode/Main.hs > "$scratch/hs-build.log" 2>&1 || {
    echo HS_BUILD_FAIL; tail -20 "$scratch/hs-build.log"; exit 1; }
mv "$scratch/hs-probe.tmp" "$scratch/hs-probe"
mkdir -p "$scratch/hs-run"
"$scratch/hs-probe" "$scratch/hs-run" 2>/dev/null | grep -E "^(delete-hardlink|delete-readonly-parent|delete-nested|delete-symlink) " > "$scratch/hs.txt"
echo "HS_PROBE_RC=$?"
chmod -R u+w "$scratch/hs-run" 2>/dev/null

echo "=== C++ (reference) ==="; cat "$scratch/cxx.txt"
echo "=== Haskell ==="; cat "$scratch/hs.txt"
# The read-only-PARENT fixture is a DELIBERATE HS adaptation, present on both
# HS branches: HS canonicalises directories to 0555, so deleting an entry needs
# the parent made writable (and restored).  C++ leaves the store root
# group-writable and simply fails on a read-only parent.  Compare the
# mode-restoration property instead of demanding the same outcome.
for f in cxx hs; do
  grep -v '^delete-readonly-parent ' "$scratch/$f.txt" > "$scratch/$f-core.txt"
done
if diff -u "$scratch/cxx-core.txt" "$scratch/hs-core.txt" > "$scratch/diff.txt" 2>&1; then
  echo "DELETE_MODE_MATCH: Haskell matches C++ on every shared-inode fixture"
  # The adaptation must still RESTORE the parent mode it toggled.
  if grep -q '^delete-readonly-parent parent-mode=0555 file-gone=1 ok' "$scratch/hs.txt"; then
    echo "DELETE_PARENT_RESTORED: the read-only parent is writable for the unlink and restored to 0555"
    exit 0
  fi
  echo "DELETE_PARENT_FAIL: the read-only parent was not restored"
  grep '^delete-readonly-parent ' "$scratch/hs.txt"
  exit 1
fi
echo "DELETE_MODE_DIFFER:"
cat "$scratch/diff.txt"
exit 1
INNER
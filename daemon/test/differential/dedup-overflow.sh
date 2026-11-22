#!/usr/bin/env bash
# Deterministic C-level regressions for goonix_dedup_link (daemon/cbits/files.c).
#
# 1. dedup-overflow-test.c — the temp-path heap overflow (CI stage1/stage2
#    evacuate+115 segfault, f4e4ab0 and earlier).  The shim appended a
#    "-<pid>-<attempt>" suffix with snprintf(temp_path + strlen(temp_path), 32,
#    ...), writing up to 32 bytes past the caller's strlen+1 buffer.  The Haskell
#    caller passes B.useAsCString, whose unfolding (useAsCString1) calls
#    newPinnedByteArray# — a pinned buffer on GHC's OWN heap, not glibc malloc.
#    The suffix wrote text over a GHC closure info pointer; the next copying GC's
#    evacuate read 0x302d2e (".-0") and segfaulted.  valgrind cannot see it (its
#    redzones are only around malloc blocks) and +RTS -DS usually misses it (10
#    bytes past a short-lived pinned buffer land in free space / a dead object).
#    The canary test forces the overflowing branch and checks a canary right
#    after a strlen+1 buffer: UNFIXED overwrites it (FAIL), FIXED does not (PASS).
#    Deterministic because it tests the C function alone.
#
# 2. dedup-linkcount-test.c — dedup parity with C++ optimise-store.cc (retry:).
#    When link_path exists with equal size and a different inode, the first loop
#    must go straight to the temp link, NOT call link(path, link_path) (which can
#    only return EEXIST) 100 times.  With -Wl,--wrap=link it asserts return 2
#    after exactly ONE link() call and ZERO link(_, link_path) attempts.  FAILS
#    on 0871201ce61 (101 calls, 100 wasteful), PASSES with the parity fix.
#    (Only run for the 4-arg shim; the parity fix sits on top of the capacity fix.)
#
# Usage: dedup-overflow.sh [FILES_C]
#   FILES_C defaults to this tree's daemon/cbits/files.c.  Point it at an older
#   files.c to demonstrate the failure; the script auto-detects the signature.
set -uo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
files_c=${1:-$root/daemon/cbits/files.c}
cc=${CC:-cc}
command -v "$cc" >/dev/null 2>&1 || cc=$(command -v gcc || command -v clang)
test -n "$cc" || { echo "no C compiler"; exit 2; }
out=$(mktemp -d /tmp/dedup-overflow.XXXXXX)
trap 'rm -rf "$out"' EXIT
# Detect the shim signature: the fixed shim takes a size_t temp_cap (4 args).
if grep -q 'char \*temp_path, size_t temp_cap' "$files_c"; then
  flag=""
  fourarg=1
  echo "shim: 4-arg (capacity-bounded) — $files_c"
else
  flag="-DUNFIXED_3ARG"
  fourarg=0
  echo "shim: 3-arg (no capacity, f4e4ab0) — $files_c"
fi
rc=0
echo "=== test 1: temp-path overflow canary ==="
if ! "$cc" -O2 -Wall $flag -I "$root/daemon/cbits" \
     -o "$out/dedup-overflow-test" \
     "$root/daemon/test/differential/dedup-overflow-test.c" "$files_c" 2>"$out/cc.err"; then
  echo "COMPILE FAILED:"; cat "$out/cc.err"; exit 2
fi
if "$out/dedup-overflow-test"; then
  echo "PASS: no temp-path overflow"
else
  echo "FAIL: temp-path overflow present"; rc=1
fi
if test "$fourarg" = 1; then
  echo "=== test 2: dedup link-count parity (C++ retry:) ==="
  if ! "$cc" -O2 -Wall -I "$root/daemon/cbits" -Wl,--wrap=link \
       -o "$out/dedup-linkcount-test" \
       "$root/daemon/test/differential/dedup-linkcount-test.c" "$files_c" 2>"$out/cc2.err"; then
    echo "COMPILE FAILED:"; cat "$out/cc2.err"; exit 2
  fi
  if "$out/dedup-linkcount-test"; then
    echo "PASS: dedup link-count parity"
  else
    echo "FAIL: dedup link-count parity (wasteful link() attempts)"; rc=1
  fi
fi
exit $rc
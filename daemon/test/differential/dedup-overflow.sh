#!/usr/bin/env bash
# Deterministic regression for the goonix_dedup_link temp-path heap overflow
# (the CI stage1/stage2 evacuate+115 segfault, f4e4ab0 and earlier).
#
# The bug: goonix_dedup_link appended a "-<pid>-<attempt>" suffix with
# snprintf(temp_path + strlen(temp_path), 32, ...), writing up to 32 bytes past
# the caller's buffer.  The Haskell caller (Files.hs deduplicateTree) passed
# B.useAsCString, which allocates only strlen+1 bytes, so the suffix overflowed
# adjacent heap.  When the overflow landed on a GHC closure's info pointer the
# next GC's evacuate read text bytes (0x302d2e = ".-0") and segfaulted; when it
# landed on malloc metadata the crash was elsewhere — hence the intermittency.
#
# This test forces the exact overflowing branch (result==0: link() EEXIST on
# every attempt with an equal-size existing target) and places a canary right
# after a strlen+1 buffer.  UNFIXED: the suffix overwrites the canary -> FAIL.
# FIXED (capacity-bounded snprintf): canary intact -> PASS.  Deterministic — no
# daemon, no GC-layout luck, no -DS needed (the overflow is in the glibc malloc
# heap that B.useAsCString uses, which the GHC -DS sanity checker does not scan).
#
# Usage: dedup-overflow.sh [FILES_C]
#   FILES_C defaults to this tree's daemon/cbits/files.c.  Point it at the
#   f4e4ab0 files.c (3-arg signature) to demonstrate the failure: the script
#   auto-detects the signature and compiles the matching call.
set -uo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
files_c=${1:-$root/daemon/cbits/files.c}
cc=${CC:-cc}
command -v "$cc" >/dev/null 2>&1 || cc=$(command -v gcc || command -v clang)
test -n "$cc" || { echo "no C compiler"; exit 2; }
out=$(mktemp -d /tmp/dedup-overflow.XXXXXX)
trap 'rm -rf "$out"' EXIT
# Detect the shim signature: the fixed shim takes a size_t temp_cap (4 args).
if grep -q 'goonix_dedup_link(const char \*path, const char \*link_path,[[:space:]]*$' "$files_c" \
   && grep -q 'char \*temp_path, size_t temp_cap' "$files_c"; then
  flag=""
  echo "shim: FIXED 4-arg (capacity-bounded) — $files_c"
else
  flag="-DUNFIXED_3ARG"
  echo "shim: UNFIXED 3-arg (no capacity) — $files_c"
fi
if ! "$cc" -O2 -Wall $flag -I "$root/daemon/cbits" \
     -o "$out/dedup-overflow-test" \
     "$root/daemon/test/differential/dedup-overflow-test.c" "$files_c" 2>"$out/cc.err"; then
  echo "COMPILE FAILED:"; cat "$out/cc.err"; exit 2
fi
"$out/dedup-overflow-test"
rc=$?
if test $rc -eq 0; then
  echo "PASS: no temp-path overflow (fixed shim)"
else
  echo "FAIL: temp-path overflow present (unfixed shim, the f4e4ab0 bug)"
fi
exit $rc
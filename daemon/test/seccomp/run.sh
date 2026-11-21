#!/usr/bin/env bash
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
build="$root/.scratch/hs6-seccomp-fixture"
rm -rf "$build"
mkdir -p "$build/ghc" "$build/include"
cp "$root/nix/libutil/seccomp.cc" "$root/nix/libutil/seccomp.hh" "$build/include/"
: "${CXX:=c++}"
: "${GHC:=ghc}"
goonix_run_capped "$CXX" -std=c++20 -O2 -I"$build/include" -I"$root/daemon/test/seccomp" \
  "$root/daemon/test/seccomp/oracle.cc" "$build/include/seccomp.cc" \
  -o "$build/oracle"
goonix_run_capped "$GHC" -O1 -package base -package bytestring -i"$root/daemon/src" \
  -outputdir "$build/ghc" -o "$build/emit" \
  "$root/daemon/test/seccomp/Emit.hs"
goonix_run_capped "$build/oracle" > "$build/cxx.bin"
goonix_run_capped "$build/emit" > "$build/hs.bin"
cmp "$build/cxx.bin" "$build/hs.bin"
test "$(stat -c %s "$build/cxx.bin")" -gt 16
cp "$build/hs.bin" "$build/mutated.bin"
printf '\001' | dd of="$build/mutated.bin" bs=1 seek=0 conv=notrunc status=none
if cmp -s "$build/cxx.bin" "$build/mutated.bin"; then
  printf 'seccomp mutation control failed\n' >&2
  exit 1
fi
printf 'seccomp filter differential: PASS (%s instructions; mutation rejected)\n' "$(( $(stat -c %s "$build/cxx.bin") / 16 ))"

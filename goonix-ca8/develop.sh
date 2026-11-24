#!/usr/bin/env bash
# goonix CA-8: develop and CALIBRATE the section 4.4 relocation check.
#
# Items come from run 13's resumed namespace store, COPIED OUT first: the gate
# is still building into that store and must not be disturbed.  Only reads
# (cp) touch it; every rewrite happens in our own scratch tree.
#
# Calibration (the reviewer's requirement): the check must FAIL on an item we
# corrupt on purpose in a copy.  Two corruptions, both of which the plan says
# scanning cannot see:
#   1. a HASH of the item's own store path written into a file (the rewriter
#      cannot reach it, so the two relocations differ);
#   2. the self path split into FRAGMENTS shorter than 8 characters.
# And a control: an item with a plain literal self reference must PASS, so a
# check that failed everything would be caught too.
set -uo pipefail
C=${1:-/home/wrath/goonix/.worktrees/goonix-implementation}
V=${2:-/home/wrath/z2-ca8-reloc}
case "$V" in /tmp/*) V="/home/wrath/z2-ca8-reloc";; esac
SRC=${GOONIX_CA8_SOURCE_STORE:-$C/.scratch/ca6-boot/store}
mkdir -p "$V/items" "$V/tmp"
cd "$C" || exit 1
printf 'SOURCE_STORE=%s\n' "$SRC"
printf 'WORK=%s\n' "$V"

echo '=== copy a few realised mesboot items OUT of the gate store (read-only) ==='
# Pick realised directories (not .drv, not -builder) from the mesboot chain.
picked=0
for pat in mesboot-headers gcc-core-mesboot0 glibc-mesboot0 gcc-mesboot0 bash-mesboot make-mesboot0; do
  for d in "$SRC"/*-"$pat"-*; do
    [ -d "$d" ] || continue
    case "$d" in *.drv|*-builder|*-debug|*-doc) continue;; esac
    b=$(basename "$d")
    if [ ! -e "$V/items/$b" ]; then
      cp -a "$d" "$V/items/$b" 2>/dev/null || continue
      chmod -R u+w "$V/items/$b" 2>/dev/null
    fi
    echo "COPIED $b"
    picked=$((picked+1))
    break
  done
done
echo "picked=$picked"
[ "$picked" -gt 0 ] || { echo 'no items copied; cannot develop'; exit 2; }

echo '=== build a synthetic control + two corrupted items ==='
nix develop '.#default' -c guile --no-auto-compile -L . -s "$C/goonix-ca8/make-fixtures.scm" "$V/items" || exit 2

echo '=== run the check over the copied items and the fixtures ==='
export GOONIX_RELOCATION_TMP="$V/tmp"
args=()
for d in "$V/items"/*; do [ -d "$d" ] && args+=("$(basename "$d")"); done
nix develop '.#default' -c guile --no-auto-compile -L . \
  -s "$C/goonix-ca8/relocation-check.scm" "$V/items" "${args[@]}"
rc=$?
echo "CHECK_RC=$rc"
exit "$rc"
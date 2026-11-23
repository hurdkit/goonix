#!/usr/bin/env bash
# goonix: build the COMMON ca-scan real-store fixture.
#
# tests/ca-scan.scm's "the two scanners agree on real store items" group reads
# GOONIX_SCAN_REAL_STORE (else the host /nix/store or /gnu/store), picks the item
# directories whose names contain -gcc-/-glibc-/-icu4c-/-wine-/-mono-, takes up to
# 12 regular files (0 < size <= 2 MiB) per item, and compares the sweep scanner
# against the single-pass scanner on each file's bytes, keyed by the first 32
# characters of the item directory name.  On a real host store the item set and
# file contents vary by machine, so the group's TEST COUNT varies (494 on z2's
# small store vs 12016 on the laptop).  This fixture is a SMALL FIXED store tree
# with the same items and the same bytes everywhere, so the group has the same
# count on every machine and every daemon.  It is read-only input to the scanner;
# no daemon is involved.
#
# Usage: scan-real-store-fixture.sh DEST
#   Creates DEST (wiping it first) as the fixture store directory.  Pass DEST as
#   GOONIX_SCAN_REAL_STORE to tests/ca-scan.scm on BOTH daemons and BOTH machines.
#
# The content is generated deterministically from the item's own 32-char hash
# (no randomness, no host input), and embeds every reference kind the scanner
# distinguishes: the whole hash, its 25 eight-byte windows, the UTF-16LE encoding,
# overlapping and truncated hashes, and arbitrary filler bytes.  Both scanners
# must agree on all of them; the fixture exercises the agreement, not a particular
# count (the count is asserted by scan-real-store.sh).
set -euo pipefail
dest=${1:?usage: scan-real-store-fixture.sh DEST}
here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../.." && pwd)

if test -e "$dest"; then
  chmod -R u+rwX "$dest" 2>/dev/null || true
  rm -rf "$dest"
fi
mkdir -p "$dest"

# Generate the fixture with the build-tree guile (the scanner's own language).
# GUILE_LOAD_PATH is set by the caller's dev shell / pre-inst-env; the generator
# uses only core modules, so it runs under any guile 3.
guile --no-auto-compile -s "$here/scan-real-store-fixture.scm" "$dest"
echo "fixture=$dest"
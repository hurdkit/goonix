#!/usr/bin/env bash
# Regression: two SQLite handles in one process must not freeze the daemon when
# one holds the WAL write lock and the other's sqlite3_step sleeps in the busy
# handler.  Compiles the daemon's own Database.hs with the contention probe and
# runs it +RTS -A1m -N (small nursery forces GC; several capabilities).  No daemon
# and no store fixture are needed, so this runs in the pre-daemon regressions.sh.
#
# PASS: handle B's insert succeeds (not DatabaseBusy) and a third thread's pure
# allocating loop finishes well under A's 2s hold + B's 60s busy_timeout.
# FAILS on the unsafe-call tree (B DatabaseBusy and/or the loop frozen at a GC),
# PASSES once the lock-taking sqlite calls are `ccall safe'.
#
# Usage: sqlite-contention.sh [TREE]
set -euo pipefail
root=${1:-$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)}
here="$root/daemon/test/differential"
. "$root/daemon/test/lib.sh"
command -v ghc >/dev/null 2>&1 || { echo "no ghc"; exit 2; }
out=$(mktemp -d /tmp/sqlite-contention.XXXXXX)
trap 'rm -rf "$out"' EXIT
# Database.hs is self-contained (boot libs + bytestring + stm); link sqlite3.
goonix_run_capped ghc -threaded -rtsopts -O0 -XGHC2024 -XBangPatterns -XOverloadedStrings -XStrictData \
  -outputdir "$out/obj" -o "$out/sqlite-contention" \
  -i"$root/daemon/src" "$here/sqlite-contention.hs" \
  -lsqlite3
rm -f "$out/db.sqlite" "$out/db.sqlite-wal" "$out/db.sqlite-shm"
goonix_run_capped "$out/sqlite-contention" "$out/db.sqlite" +RTS -A1m -N -RTS
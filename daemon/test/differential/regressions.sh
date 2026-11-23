#!/usr/bin/env bash
# Deterministic regression runner: the gates that need NO root and NO store, so
# CI can run them on every pin move before any daemon is started.  Each is a
# standalone script that exits non-zero on the regression it guards:
#   - cabal-modules.sh: every tracked Goonix module is in the cabal package
#     (a clean `nix build .#guix-daemon-hs` would otherwise fail to find it).
#   - dedup-overflow.sh: the dedup temp-path heap overflow canary AND the dedup
#     link-count parity harness (two C tests compiled against daemon/cbits/files.c).
#   - delete-hardlink.sh: deleteTree must not chmod the file it unlinks.  A
#     deduplicated store file is hard-linked into .links (one inode, several
#     paths); the GC deleting one link while a build execs another must not strip
#     the shared inode's exec bit (the sandbox EACCES race).  Compiles the daemon's
#     Files.hs; FAILS pre-fix (mode 0555 -> 0644), PASSES after.
#   - sqlite-contention.sh: two SQLite handles in one process must not freeze the
#     daemon when one holds the WAL write lock and the other's sqlite3_step sleeps
#     in the busy handler (the lock-taking sqlite calls must be `ccall safe').
#     Compiles the daemon's Database.hs with the probe; runs +RTS -A1m -N.
#   - socket-idle.sh: an idle client (sends nothing) must not freeze the daemon's
#     other threads; readSocket must wait through the IO manager, not a raw
#     blocking fdRead.  Compiles the daemon's Socket.hs; runs +RTS -A1m -N.
#   - offload-eof.sh: a hook that closes its output before replying must make
#     requestOffload raise a storeError within a bounded time, not spin flooding
#     newlines (receiveLine throws at EOF, as C++ readLine).  FAILS pre-fix.
#   - offload-flood.sh: finishOffload must drain ALL of a hook's output (>64 KiB
#     with pauses) and return; the non-blocking output fd hits EAGAIN between
#     bursts, which is NOT EOF.  FAILS pre-fix (drainFd treated EAGAIN as EOF ->
#     bytes lost / hang).  Both compile the daemon sources; run +RTS -A1m -N.
# Fails if ANY of them fails, naming the failing test.
#
# export-memory.sh is deliberately NOT here: it needs a running daemon and a
# store fixture (it builds outputs and measures the daemon's VmHWM), so it is a
# differential daemon test, not a no-store regression.  It runs via the
# differential harness against both daemons, not in this pre-daemon runner.
#
# Usage: regressions.sh [TREE]
set -uo pipefail
root=${1:-$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)}
here="$root/daemon/test/differential"
rc=0
run() { # name script...
  local name=$1; shift
  echo "=== regression: $name ==="
  if "$@"; then
    echo "PASS: $name"
  else
    echo "FAIL: $name"
    rc=1
  fi
}
run cabal-modules bash "$here/cabal-modules.sh" "$root"
run dedup-overflow bash "$here/dedup-overflow.sh" "$root/daemon/cbits/files.c"
run delete-hardlink bash "$here/delete-hardlink.sh" "$root"
run sqlite-contention bash "$here/sqlite-contention.sh" "$root"
run socket-idle bash "$here/socket-idle.sh" "$root"
run child-wait bash "$here/child-wait.sh" "$root"
run offload-idle bash "$here/offload-idle.sh" "$root"
run offload-eof bash "$here/offload-eof.sh" "$root"
run offload-flood bash "$here/offload-flood.sh" "$root"
if test $rc -eq 0; then
  echo "ALL REGRESSIONS PASS"
else
  echo "REGRESSIONS FAILED"
fi
exit $rc

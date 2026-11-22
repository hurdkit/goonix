#!/usr/bin/env bash
# Deterministic regression runner: the gates that need NO root and NO store, so
# CI can run them on every pin move before any daemon is started.  Each is a
# standalone script that exits non-zero on the regression it guards:
#   - cabal-modules.sh: every tracked Goonix module is in the cabal package
#     (a clean `nix build .#guix-daemon-hs` would otherwise fail to find it).
#   - dedup-overflow.sh: the dedup temp-path heap overflow canary AND the dedup
#     link-count parity harness (two C tests compiled against daemon/cbits/files.c).
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
if test $rc -eq 0; then
  echo "ALL REGRESSIONS PASS"
else
  echo "REGRESSIONS FAILED"
fi
exit $rc

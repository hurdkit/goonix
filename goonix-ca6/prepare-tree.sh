#!/usr/bin/env bash
# goonix: build the tree the way a gate needs it, before the gate runs.
#
# Why this exists (reviewer, DECISIONS.md 37): the gate runners start guile with
# --no-auto-compile, so an unbuilt tree is INTERPRETED, which is not the load
# path a built tree uses.  Counted run 18c died lowering the VM image on
# upstream's jq/oniguruma macro because its worktree had no .go files at all.
# The gate now refuses to run uncompiled (gate-lib.sh); this script is how a job
# gets compiled, identically on the laptop and on zergling2.
#
# usage: prepare-tree.sh [JOBS] [IMPL]
#   JOBS  parallelism for make.  Default: GOONIX_GATE_JOBS, else 6.
#         zergling2's cap is 6 (the user's CPU rule: no job may use all 24
#         threads; zergling2-lanes/DECISIONS.md "CPU limit").  The laptop may
#         pass more.  Never default to nproc.
#   IMPL  the checkout to build.  Default: this script's own tree.
#
# It is idempotent: bootstrap only when configure is absent, configure only when
# config.status is absent, then make (which is a no-op when everything is
# current).  It ends by asserting the compiled-module precondition, so a job
# that calls only this script still cannot proceed on a stale tree.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
JOBS=${1:-${GOONIX_GATE_JOBS:-6}}
IMPL=${2:-$(cd "$HERE/.." && pwd -P)}
case "$JOBS" in ''|*[!0-9]*) echo "prepare-tree: JOBS must be a number, got '$JOBS'" >&2; exit 2;; esac
[ "$JOBS" -ge 1 ] || JOBS=1
cd "$IMPL"
echo "PREPARE_TREE=$IMPL"
echo "PREPARE_JOBS=$JOBS"

build() {
  if [ ! -x ./configure ]; then
    echo '=== bootstrap ==='
    ./bootstrap
  fi
  if [ ! -f ./config.status ]; then
    echo '=== configure ==='
    ./configure --localstatedir=/var --sysconfdir=/etc ac_cv_guix_test_root=/tmp/gxv-test
  fi
  # The generated header the daemon sources include; make it first so a -j
  # build cannot race it (measured on z2: local-store.cc failed with
  # "schema.sql.hh: No such file or directory").
  echo '=== schema header ==='
  make nix/libstore/schema.sql.hh
  echo "=== make -j$JOBS ==="
  nice -n 10 make -j"$JOBS"
}

# The dev shell must come from THIS worktree's flake: the main checkout has no
# libarchive, so a shell taken from it configures without goonix-ca-scan and the
# deep-scan refusals silently never happen (DECISIONS.md 12).
if [ -z "${IN_NIX_SHELL:-}" ]; then
  exec nix develop '.#default' -c bash "$0" "$JOBS" "$IMPL"
fi
build

source "$HERE/gate-lib.sh"
goonix_gate_require_compiled "$IMPL"
echo 'PREPARE_TREE_OK'
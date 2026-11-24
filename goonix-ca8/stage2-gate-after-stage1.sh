#!/usr/bin/env bash
# goonix: the CA-8 stage 2 TOOLCHAIN gate, queued behind stage1 in the build lane.
#
# It runs the one command recorded in STATUS: stage2 with the DEFAULT chain
# (glibc-final, gcc-final, guile-final) against stage1's OWN scratch, so it builds
# only the tail on the ladder stage1 realised.  The hand-off was proven on
# .scratch/ca8-stage2-c (DECISIONS/STATUS: binutils-mesboot0 built, ladder not
# rebuilt).
#
# It REFUSES, before doing anything, unless:
#   1. stage1's process has exited;
#   2. stage1's own log carries stage1's SUCCESS verdict;
#   3. MemAvailable >= MemoryMax + 8 GiB (the laptop lane rule).
# A refusal is not a gate result: it prints why and exits non-zero.
set -uo pipefail

IMPL=/home/wrath/goonix/.worktrees/goonix-implementation
SCRATCH="$IMPL/.scratch/ca8-laptop"
MEM_MAX_GIB=8
RESERVE_GIB=8
CORES=2
# Sized from measured times: the C chain took 14m35s for 3 items and
# binutils-mesboot0 alone took 27m57s.  glibc-final + gcc-final + guile-final on
# an already-built ladder are three real builds; 6h is generous but bounded, so
# the job STOPS rather than being waited out.
TIMEOUT=21600

say() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

say "QUEUED-AT=$(date '+%F %T') stage2 toolchain gate; scratch=$SCRATCH"

# --- refuse 1: stage1 must have exited -------------------------------------
# Match the runner and its timeout wrapper, not this script.  The pgrep form
# matched my own z2 tickets and refused on 2026-11-24 07:11:28 with no stage1
# running; use the shared argv-shape detector (goonix-ca6/gate-lib.sh).
source "$(dirname "${BASH_SOURCE[0]}")/../goonix-ca6/gate-lib.sh"
if pid=$(goonix_stage_running stage1); then
  say "REFUSE: stage1 is still running (runner pid $pid)"
  exit 1
fi
if pgrep -f 'timeout 28800 bash -c cd /home/wrath/goonix/.worktrees/goonix-implementation' >/dev/null 2>&1; then
  say 'REFUSE: stage1 timeout wrapper still present'
  exit 1
fi

# --- refuse 2: stage1 must have SUCCEEDED, by its own verdict --------------
# The runner writes "STAGE=stage1 EXIT=<n>" to $scratch/results and the client
# prints "STAGE1 TOTALS ... failed=0".  Require BOTH, and EXIT=0.
results="$SCRATCH/results"
out="$SCRATCH/stage1.out"
if [ ! -f "$results" ]; then
  say "REFUSE: no stage1 results file ($results)"
  exit 1
fi
if ! grep -qE '^STAGE=stage1 EXIT=0$' "$results"; then
  say "REFUSE: stage1 did not record EXIT=0; results say:"
  grep -E '^STAGE=stage1' "$results" | tail -3
  exit 1
fi
if ! grep -qE '^STAGE1 TOTALS .*failed=0' "$out" 2>/dev/null; then
  say 'REFUSE: stage1.out has no "STAGE1 TOTALS ... failed=0"'
  grep -aE '^STAGE1 TOTALS' "$out" 2>/dev/null | tail -2
  exit 1
fi
say 'PRECONDITION OK: stage1 exited and recorded EXIT=0 with failed=0'

# --- refuse 3: memory headroom --------------------------------------------
avail_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
need_kib=$(( (MEM_MAX_GIB + RESERVE_GIB) * 1024 * 1024 ))
if [ "${avail_kib:-0}" -lt "$need_kib" ]; then
  say "REFUSE: MemAvailable ${avail_kib} KiB < required ${need_kib} KiB (${MEM_MAX_GIB}G cap + ${RESERVE_GIB}G reserve)"
  exit 1
fi
say "MEMORY OK: MemAvailable ${avail_kib} KiB >= ${need_kib} KiB"

# --- run -------------------------------------------------------------------
cd "$IMPL" || exit 1
say "START stage2 toolchain (default chain), cores=$CORES cap=${MEM_MAX_GIB}G timeout=${TIMEOUT}s"
export GOONIX_CA8_SCRATCH="$SCRATCH"
export GOONIX_DOWNLOAD_CACHE=http://10.0.30.4:8480
export GOONIX_GATE_JOBS="$CORES"
unset GOONIX_CA8_STAGE2_CHAIN
systemd-run --user --scope --quiet \
  -p MemoryMax="${MEM_MAX_GIB}G" -p MemorySwapMax=0 -- \
  timeout "$TIMEOUT" bash goonix-ca8/ca8-core-run.sh stage2 goonix-ca8/ca8-stage2.scm
rc=$?
say "END stage2 toolchain rc=$rc"
exit "$rc"
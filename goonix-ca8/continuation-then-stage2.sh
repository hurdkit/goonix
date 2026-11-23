#!/usr/bin/env bash
# goonix: ONE build-lane job doing (a) the CA-8 stage1 CONTINUATION on the
# existing scratch, then (b) the stage2 toolchain gate, only if (a) succeeded.
#
# (a) is a CONTINUATION, not the counted gate (DECISIONS 57).  The original
# stage1 (commit 2565a86d63b, pid 3350860 / timeout 28800, started 19:32:07)
# reaches chain position 10 of 18 and is killed by its own 8h timeout at 03:32
# with NO VERDICT.  This job REUSES .scratch/ca8-laptop - it does NOT wipe - so
# its BUILT-HERE set is the tail, not the ladder.  The counted fresh stage1 runs
# separately on z2build (job z2-ca8-stage1-counted, GOONIX_CA8_FRESH=1).
#
# Refuses, before doing anything, unless:
#   1. the 2565a86d63b stage1 process AND its timeout wrapper have exited;
#   2. MemAvailable >= MemoryMax + 8 GiB (the laptop lane rule).
# A refusal is not a gate result: it prints why and exits non-zero.
set -uo pipefail

IMPL=/home/wrath/goonix/.worktrees/goonix-implementation
SCRATCH="$IMPL/.scratch/ca8-laptop"
MEM_MAX_GIB=8
RESERVE_GIB=8
CORES=2

# (a) CONTINUATION timeout.  Measured remaining estimate (DECISIONS 57) was
# ~10800s for the 8 items after gcc-mesboot1, plus ~1000-2000s left on
# gcc-mesboot1 itself.  gcc-mesboot1 is KILLED by the timeout, so it restarts
# from zero: add its full measured cost.  gcc-core-mesboot1 took 5741s and
# gcc-mesboot1 had already run >=5396s when assessed, so budget 6000s for it.
#   6000 (gcc-mesboot1 from zero) + 10800 (remaining 8) = 16800s
# Reviewer: at least TWICE the measured remaining estimate.  2 * 16800 = 33600s.
CONT_TIMEOUT=33600
# (b) stage2: 6h, unchanged from the accepted ticket.
STAGE2_TIMEOUT=21600

say() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

say "QUEUED-AT=$(date '+%F %T') CA-8 CONTINUATION + stage2 (one job); scratch=$SCRATCH"
say "LABEL: (a) is a CONTINUATION, not the counted gate (DECISIONS 57). Scratch REUSED, not wiped."
say "TIMEOUTS: continuation=${CONT_TIMEOUT}s (2 x measured 16800s), stage2=${STAGE2_TIMEOUT}s"

# --- refuse 1: the original stage1 must have exited -------------------------
if pgrep -f 'ca8-core-run\.sh stage1' >/dev/null 2>&1; then
  say 'REFUSE: the 2565a86d63b stage1 is still running (ca8-core-run.sh stage1 present)'
  exit 1
fi
if pgrep -f 'timeout 28800 bash -c cd /home/wrath/goonix/.worktrees/goonix-implementation' >/dev/null 2>&1; then
  say 'REFUSE: the original stage1 timeout 28800 wrapper is still present'
  exit 1
fi
say 'PRECONDITION OK: the original stage1 process and its timeout wrapper have exited'

# --- refuse 2: memory headroom ---------------------------------------------
avail_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
need_kib=$(( (MEM_MAX_GIB + RESERVE_GIB) * 1024 * 1024 ))
if [ "${avail_kib:-0}" -lt "$need_kib" ]; then
  say "REFUSE: MemAvailable ${avail_kib} KiB < required ${need_kib} KiB (${MEM_MAX_GIB}G cap + ${RESERVE_GIB}G reserve)"
  exit 1
fi
say "MEMORY OK: MemAvailable ${avail_kib} KiB >= ${need_kib} KiB"

cd "$IMPL" || exit 1
export GOONIX_CA8_SCRATCH="$SCRATCH"
export GOONIX_DOWNLOAD_CACHE=http://10.0.30.4:8480
export GOONIX_GATE_JOBS="$CORES"

# --- (a) the CONTINUATION --------------------------------------------------
# Record what the scratch already holds, so the continuation's coverage is
# explicit and cannot be mistaken for the ladder (DECISIONS 57).
say "CONTINUATION found store items already present: $(ls "$SCRATCH/store" 2>/dev/null | wc -l)"
if [ -f "$SCRATCH/results" ]; then
  say 'CONTINUATION prior verdict lines:'
  grep -E '^STAGE=' "$SCRATCH/results" | tail -3
fi
# GOONIX_CA8_FRESH is deliberately NOT set: this run reuses the scratch.
unset GOONIX_CA8_FRESH
say "START (a) CONTINUATION cores=$CORES cap=${MEM_MAX_GIB}G timeout=${CONT_TIMEOUT}s"
systemd-run --user --scope --quiet \
  -p MemoryMax="${MEM_MAX_GIB}G" -p MemorySwapMax=0 -- \
  timeout "$CONT_TIMEOUT" bash goonix-ca8/ca8-core-run.sh stage1 goonix-ca8/ca8-stage1.scm
cont_rc=$?
say "END (a) CONTINUATION rc=$cont_rc"

# --- gate between (a) and (b): (a)'s OWN verdict must be success ------------
results="$SCRATCH/results"
out="$SCRATCH/stage1.out"
if [ ! -f "$results" ] || ! grep -qE '^STAGE=stage1 EXIT=0$' "$results"; then
  say 'STOP: (a) did not record STAGE=stage1 EXIT=0; stage2 NOT started. Results say:'
  grep -E '^STAGE=stage1' "$results" 2>/dev/null | tail -3
  exit "$cont_rc"
fi
if ! grep -qE '^STAGE1 TOTALS .*failed=0' "$out" 2>/dev/null; then
  say 'STOP: stage1.out has no "STAGE1 TOTALS ... failed=0"; stage2 NOT started.'
  grep -aE '^STAGE1 TOTALS' "$out" 2>/dev/null | tail -2
  exit 1
fi
say 'PRECONDITION OK: (a) recorded EXIT=0 with failed=0'

# --- (b) stage2, default chain, same scratch -------------------------------
avail_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
if [ "${avail_kib:-0}" -lt "$need_kib" ]; then
  say "REFUSE (b): MemAvailable ${avail_kib} KiB < required ${need_kib} KiB"
  exit 1
fi
unset GOONIX_CA8_STAGE2_CHAIN
say "START (b) stage2 toolchain (default chain) cores=$CORES cap=${MEM_MAX_GIB}G timeout=${STAGE2_TIMEOUT}s"
systemd-run --user --scope --quiet \
  -p MemoryMax="${MEM_MAX_GIB}G" -p MemorySwapMax=0 -- \
  timeout "$STAGE2_TIMEOUT" bash goonix-ca8/ca8-core-run.sh stage2 goonix-ca8/ca8-stage2.scm
rc=$?
say "END (b) stage2 toolchain rc=$rc"
exit "$rc"
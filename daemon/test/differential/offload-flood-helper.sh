#!/usr/bin/env bash
# Regression (b) helper: a fake offload hook that ACCEPTS, then writes well over
# the 64 KiB pipe buffer of diagnostics to STDOUT (the agent/output pipe that
# finishOffload's drainFd reads) WITH PAUSES, then exits 0.  The pauses make the
# pipe momentarily empty between bursts, so a non-blocking fdRead hits EAGAIN
# repeatedly; a drain that treats EAGAIN as EOF stops early and loses the later
# bursts, and once >64 KiB is pending the helper blocks in write() and the build
# hangs.  Writes EXACTLY 262144 bytes (256 KiB): 4096 lines of 64 bytes each, in
# 8 bursts of 512 lines with 50ms pauses, so the test can assert the exact count.
# Each line is 63 chars + newline = 64 bytes (zero-padded indices keep it fixed).
read -r _request
printf '# accept\n'
# Read the two accept lines (inputs, outputs) so the daemon's acceptOffload completes.
read -r _inputs
read -r _outputs
i=0
while test "$i" -lt 8; do
  j=0
  while test "$j" -lt 512; do
    # 63-char line: fixed-width fields so every line is exactly 63 chars + \n.
    printf 'offload-diagnostic-burst-%02d-line-%04d-padding-padding-padding-p\n' "$i" "$j"
    j=$((j + 1))
  done
  sleep 0.05
  i=$((i + 1))
done
exit 0
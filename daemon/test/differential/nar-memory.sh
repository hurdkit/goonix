#!/usr/bin/env bash
# Regression: the daemon's peak memory must NOT scale with the size of a build
# output.  C++ streams the NAR through a hash sink + counting sink (one pass,
# bounded working set); a daemon that materialises the whole NAR in memory to
# measure its length or hash it pins ~output-size bytes per registration.
#
# Builds one output of SMALL MiB, records the daemon's VmHWM (peak RSS), then
# builds one of LARGE MiB in the SAME daemon and records VmHWM again.  Asserts
# the peak-memory GROWTH from small to large is far below the output-size growth
# (no hard-coded byte limit; the assertion is a ratio against the size delta).
# Fails on a whole-NAR-in-memory daemon; passes with the streaming fix.
#
# The builder is bootstrap bash builtins only (printf '%*s' loop) — no network,
# no guile, no coreutils.  Only the NAR size matters, so spaces suffice.
#
# Usage: nar-memory.sh [DAEMON] [FIXTURE]
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${1:-${GOONIX_TEST_DAEMON:-$root/guix-daemon}}
fixture=${2:-$root/.scratch/nar-memory}
if test -e "$fixture"; then chmod -R u+rwX "$fixture" 2>/dev/null || true; rm -rf "$fixture"; fi
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix"
export NAR_MEM_FIXTURE="$fixture" GUILE_AUTO_COMPILE=0
rm -f "$GUIX_DAEMON_SOCKET"
test ! -e "$GUIX_DAEMON_SOCKET"
goonix_start_capped \
  "$root/pre-inst-env" "$daemon" --disable-chroot --listen="$GUIX_DAEMON_SOCKET" \
  >"$fixture/daemon.log" 2>&1
pid=$GOONIX_TEST_PID
daemon_scope=$GOONIX_TEST_SCOPE
trap 'goonix_stop_capped "$pid" "$daemon_scope"' EXIT
for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
test -S "$GUIX_DAEMON_SOCKET"

# Find the daemon by its EXECUTABLE, not by ps text: systemd-run, timeout and
# bash carry the same command line, so a cmdline match alone finds wrappers.
# Take every PID whose cmdline names this fixture's unique socket AND whose
# /proc/PID/exe resolves to the binary under test.  The C++ daemon forks a
# per-connection child with the same exe, and that child does the work, so we
# sample EVERY match and take the largest VmHWM.
want=$(readlink -f "$daemon")
daemon_pids() {
  local p
  for p in $(pgrep -f -- "$GUIX_DAEMON_SOCKET" 2>/dev/null); do
    if test "$(readlink "/proc/$p/exe" 2>/dev/null)" = "$want"; then
      printf '%s\n' "$p"
    fi
  done
}
mapfile -t pids < <(daemon_pids)
test "${#pids[@]}" -gt 0
vmhwm_max() { # largest VmHWM across all daemon processes (parent + forked child)
  local p h max=0
  for p in "${pids[@]}"; do
    h=$(awk '/VmHWM/{print $2}' "/proc/$p/status" 2>/dev/null || true)
    test -n "$h" || continue
    if test "$h" -gt "$max"; then max=$h; fi
  done
  printf '%s' "$max"
}
reset_hwm() { # reset the high-water mark on every match before each timed build
  local p
  for p in "${pids[@]}"; do
    printf 5 > "/proc/$p/clear_refs" 2>/dev/null || true
  done
}

# Two output sizes: 8 MiB and 96 MiB (12x).
small_mb=8
large_mb=96
build_size() { # mb
  NAR_MEM_MB=$1 goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile \
    "$root/daemon/test/differential/nar-memory.scm"
}

printf 'daemon exe=%s pids=%s\n' "$want" "${pids[*]}"
reset_hwm
build_size "$small_mb"
hwm_small=$(vmhwm_max)
printf 'small=%s MiB VmHWM=%s kB\n' "$small_mb" "$hwm_small"
# A forked per-connection child may appear during the build; refresh the list.
mapfile -t pids < <(daemon_pids)
reset_hwm
build_size "$large_mb"
mapfile -t pids < <(daemon_pids)
hwm_large=$(vmhwm_max)
printf 'large=%s MiB VmHWM=%s kB\n' "$large_mb" "$hwm_large"

# Growth in peak memory must be far below growth in output size.  A streaming
# daemon adds only a bounded working set (a few MiB); a whole-NAR-in-memory
# daemon adds ~the large output size.  Assert growth < 1/4 of the size delta
# (no absolute byte limit).  Size delta = 88 MiB = 90112 kB.
size_delta_kb=$(( (large_mb - small_mb) * 1024 ))
growth_kb=$(( hwm_large - hwm_small ))
if test "$growth_kb" -lt 0; then growth_kb=0; fi
threshold_kb=$(( size_delta_kb / 4 ))
printf 'size-delta=%s kB memory-growth=%s kB threshold=%s kB\n' "$size_delta_kb" "$growth_kb" "$threshold_kb"
if test "$growth_kb" -gt "$threshold_kb"; then
  printf 'nar-memory: FAIL — peak memory grew %s kB for a %s kB larger output (materialises the NAR)\n' "$growth_kb" "$size_delta_kb" >&2
  exit 1
fi
printf 'nar-memory peak-growth: PASS (small-hwm=%s large-hwm=%s growth=%s threshold=%s)\n' "$hwm_small" "$hwm_large" "$growth_kb" "$threshold_kb"
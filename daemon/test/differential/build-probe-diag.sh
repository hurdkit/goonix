#!/usr/bin/env bash
# Diagnostic: run build-probe-nons with noisy / silent / no helper, and a bare
# module-load precheck, capturing every log to stdout (remote.log keeps it even
# if the remote /tmp is cleaned).  Isolates WHERE the build client hangs.
set -uo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
here="$root/daemon/test/differential"
devinfo=$(cd "$root" && nix develop .#default -c bash -c 'echo "GLP=$GUILE_LOAD_PATH"; echo "GLCP=$GUILE_LOAD_COMPILED_PATH"')
dev_glp=$(echo "$devinfo" | grep '^GLP=' | sed 's/^GLP=//')
dev_glcp=$(echo "$devinfo" | grep '^GLCP=' | sed 's/^GLCP=//')
echo "DEV_GLP=$dev_glp"
echo "DEV_GLCP=$dev_glcp"
echo "=== module-load precheck (no daemon) ==="
timeout 40 env -i LC_ALL=C.UTF-8 PATH=/nonexistent \
  GUILE_LOAD_PATH="$root:$dev_glp" GUILE_LOAD_COMPILED_PATH="$root:$dev_glcp" GUIX_UNINSTALLED=1 \
  "$root/guile" --no-auto-compile -c '(use-modules (guix store) (guix derivations) (guix utils) (guix tests) (gnu packages bootstrap)) (display "MODULES_OK\n")' 2>&1 | head -20
echo "MODULE_PRECHECK_RC=$?"
for mode in silent noisy; do
  echo "=================== MODE=$mode ==================="
  timeout 120 bash "$here/build-probe-nons.sh" "/tmp/bp-diag-$mode" "$mode" "$root" 2>&1 | grep -vE 'progress line' | head -30
  echo "MODE=$mode wrapper_rc=$?"
  echo "--- raw build-probe.log (non-progress) ---"
  grep -vE 'progress line' "/tmp/bp-diag-$mode/buildprobe/build-probe.log" 2>/dev/null | head -20
  echo "(progress lines: $(grep -c 'progress line' "/tmp/bp-diag-$mode/buildprobe/build-probe.log" 2>/dev/null))"
  echo "--- daemon.log (non-progress) ---"
  grep -vE 'progress line' "/tmp/bp-diag-$mode/buildprobe/daemon.log" 2>/dev/null | head -10
done
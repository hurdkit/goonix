#!/usr/bin/env bash
# The stress gate's namespace part: runs as PID 1 of the job's OWN PID namespace,
# entered by stress-gate.sh after the uid/gid maps and the bind mounts are in
# place.
#
# Usage (from the runner): stress-gate-part.sh WORK ROOT DAEMON MODE \
#   PAYLOAD_HASH DEV_GLP DEV_GLCP
set -uo pipefail
work=${1:?work}; root=${2:?root}; daemon=${3:?daemon}; mode=${4:?mode}
payload_hash=${5:?payload}; dev_glp=${6:-}; dev_glcp=${7:-}
here="$root/daemon/test/differential"

# Job isolation check: refuse to start the daemon outside a private PID
# namespace (one job's build-user kill(-1) must not reach another's builders).
. "$root/daemon/test/differential/pidns-guard.sh" "stress-gate" || exit 3

    # Local HTTP server for the substitute client (root-ci-http.sh serves payload.txt).
    socat TCP-LISTEN:18080,reuseaddr,fork \
      EXEC:"$here/root-ci-http.sh $work/payload.txt" > "$work/http.log" 2>&1 &
    http_pid=$!
    sleep 1
    # The noisy helper needs an absolute bash + a working PATH (the daemon spawns it
    # with PATH=/nonexistent), exactly as root-ci-substitute.sh wraps its helpers.
    bash_abs=$(command -v bash); dev_path="$PATH"
    helper="$work/stress-noisy-helper.wrapper"
    { printf "#!%s\n" "$bash_abs"; printf "export PATH=%s\n" "$dev_path";
      cat "$here/stress-noisy-helper.sh"; } > "$helper"
    chmod +x "$helper"

    run_mode() { # rts-label rts-args...
      local rtslabel=$1; shift
      echo "=== stress gate: daemon RTS $rtslabel ==="
      if test "$mode" = worktree; then
        env -i TMPDIR="$work/build" LC_ALL=C.UTF-8 PATH=/nonexistent GUIX="$helper" \
          GUILE_LOAD_PATH="$root:$dev_glp" GUILE_LOAD_COMPILED_PATH="$root:$dev_glcp" GUIX_UNINSTALLED=1 \
          GUIX_SANDBOX="$root/guix-sandbox" \
          "$daemon" --build-users-group=guixbuild --max-jobs=2 --substitute-urls="" --no-substitutes --no-offload \
          "$@" > "$work/daemon-$rtslabel.log" 2>&1 &
      else
        env -i TMPDIR="$work/build" LC_ALL=C.UTF-8 PATH=/nonexistent GUIX="$helper" \
          "$daemon" --build-users-group=guixbuild --max-jobs=2 --substitute-urls="" --no-substitutes \
          "$@" > "$work/daemon-$rtslabel.log" 2>&1 &
      fi
      dpid=$!
      local i
      for i in $(seq 1 300); do test -S /var/guix/daemon-socket/socket && break; kill -0 "$dpid" 2>/dev/null || break; sleep .05; done
      if ! test -S /var/guix/daemon-socket/socket; then
        echo "DAEMON DID NOT START ($rtslabel)"; head -20 "$work/daemon-$rtslabel.log"; kill $dpid 2>/dev/null; return 2
      fi
      # Launch all clients as separate PROCESSES (the real one-daemon-many-clients
      # scenario; Guile threads share the build-handler prompt and break builds).
      local sock=/var/guix/daemon-socket/socket
      local stop="$work/stop-$rtslabel"
      rm -f "$stop"
      local timeout_abs
      timeout_abs=$(command -v timeout)
      run_guile() { # script logfile args...
        local script=$1 log=$2; shift 2
        env -i LC_ALL=C.UTF-8 PATH=/nonexistent \
          GUILE_LOAD_PATH="$root:$dev_glp" GUILE_LOAD_COMPILED_PATH="$root:$dev_glcp" GUIX_UNINSTALLED=1 \
          SILENT_SECONDS="${SILENT_SECONDS:-6}" \
          "$timeout_abs" "${STRESS_CLIENT_TIMEOUT:-120}" \
          "$root/guile" --no-auto-compile "$here/$script" "$@" > "$log" 2>&1
      }
      local nb=${STRESS_BUILDS:-3}
      local pids=() names=()
      # watchdog first, samples the whole window
      run_guile stress-watchdog.scm "$work/watchdog-$rtslabel.log" "$sock" "$stop" "${WATCHDOG_BOUND:-3}" &
      pids+=($!); names+=(watchdog)
      sleep 0.3
      local i
      for i in $(seq 0 $((nb - 1))); do
        run_guile stress-build.scm "$work/build-$i-$rtslabel.log" "$sock" "stress-build-$i" &
        pids+=($!); names+=("build-$i")
      done
      run_guile stress-substitute.scm "$work/substitute-$rtslabel.log" "$sock" "$payload_hash" &
      pids+=($!); names+=(substitute)
      run_guile stress-gc.scm "$work/gc-$rtslabel.log" "$sock" "${STRESS_GC_ROUNDS:-4}" &
      pids+=($!); names+=(gc)
      run_guile stress-roots.scm "$work/roots-$rtslabel.log" "$sock" "${STRESS_ROOT_ROUNDS:-6}" &
      pids+=($!); names+=(roots)
      # join every client except the watchdog, recording each result
      local rc=0 j
      for j in "${!pids[@]}"; do
        if test "${names[$j]}" = watchdog; then continue; fi
        if wait "${pids[$j]}"; then
          echo "client ${names[$j]}: PASS"
        else
          echo "client ${names[$j]}: FAIL"; rc=1
        fi
        cat "$work/${names[$j]}-$rtslabel.log" 2>/dev/null | grep -E "PASS|FAIL|error" | head -3
      done
      # stop the watchdog and join it
      touch "$stop"
      if wait "${pids[0]}"; then echo "client watchdog: PASS"; else echo "client watchdog: FAIL"; rc=1; fi
      cat "$work/watchdog-$rtslabel.log" 2>/dev/null | grep -E "watchdog:" | head -5
      # store verification: every built output present + valid, rooted output alive
      if run_guile stress-verify.scm "$work/verify-$rtslabel.log" "$sock" "$work"; then
        echo "store-verify: PASS"
      else
        echo "store-verify: FAIL"; rc=1
      fi
      cat "$work/verify-$rtslabel.log" 2>/dev/null | head -3
      if test $rc -eq 0; then echo "STRESS_GATE ($rtslabel): PASS"; else echo "STRESS_GATE ($rtslabel): FAIL"; fi
      kill $dpid 2>/dev/null; wait $dpid 2>/dev/null; dpid=
      rm -f /var/guix/daemon-socket/socket
      return $rc
    }

    rc=0
    run_mode normal || rc=1
    run_mode a1m +RTS -A1m -N -RTS || rc=1
    exit $rc

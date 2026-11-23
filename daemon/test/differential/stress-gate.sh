#!/usr/bin/env bash
# goonix: one-process-many-clients concurrency stress gate (reviewer, pre-host-switch).
# Runs root-ci's setup (namespace root, build users, chroot, the installed package
# daemon) and then stress-client.scm: several build clients + a noisy-log/silent
# substitute client + a GC client + a roots/temp-roots client + a watchdog, all at
# once against ONE daemon.  Runs the client TWICE: once with the daemon's normal RTS
# options and once with -A1m (small nursery forces GC, exposing capability freezes).
#
# This is a STRESS gate, not a quick regression: it builds derivations in the chroot
# and runs a ~6s silent helper, so it takes a few minutes.  It is deliberately NOT
# wired into root-ci.sh's fast path; run it on its own before the host switch.
#
# Usage: stress-gate.sh DAEMON [LABEL]
#   ROOT_CI_MODE=installed (default) | worktree   (as root-ci.sh)
#   WATCHDOG_BOUND=3  STRESS_BUILDS=3  SILENT_SECONDS=6  (passed to the client/helper)
set -uo pipefail
daemon=${1:?usage: stress-gate.sh DAEMON [LABEL]}
label=${2:-$(basename "$daemon")}
mode=${ROOT_CI_MODE:-installed}
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
here="$root/daemon/test/differential"
work=/tmp/pr6-root-ci/$label
uid=$(id -u)
gid=$(id -g)

bash "$here/root-ci-setup.sh" "$daemon" "$label" || exit 1
daemon=$(readlink -f "$daemon")

# Payload hash + dev-shell guile load paths, as root-ci.sh.
devinfo=$(cd "$root" && nix develop .#default -c bash -c 'guile --no-auto-compile -L . -c "(use-modules (guix hash) (guix base32) (gcrypt hash) (rnrs io ports)) (display (bytevector->nix-base32-string (sha256 (call-with-input-file \"'"$work"'/payload.txt\" get-bytevector-all)))) (newline)"; echo "GLP=$GUILE_LOAD_PATH"; echo "GLCP=$GUILE_LOAD_COMPILED_PATH"')
payload_hash=$(echo "$devinfo" | sed -n 1p)
dev_glp=$(echo "$devinfo" | grep '^GLP=' | sed 's/^GLP=//')
dev_glcp=$(echo "$devinfo" | grep '^GLCP=' | sed 's/^GLCP=//')
echo "payload_hash=$payload_hash mode=$mode"

export PATH=/run/wrappers/bin:$PATH
timeout 900 unshare --user \
  --map-users=0:"$uid":1 --map-users=1:100000:65536 \
  --map-groups=0:"$gid":1 --map-groups=1:100000:65536 \
  --mount -- bash -c '
    set -uo pipefail
    work="'"$work"'"; root="'"$root"'"; daemon="'"$daemon"'"; mode="'"$mode"'"
    payload_hash="'"$payload_hash"'"; dev_glp="'"$dev_glp"'"; dev_glcp="'"$dev_glcp"'"
    here="$root/daemon/test/differential"
    for port in 18080 19418; do
      if ss -ltn 2>/dev/null | grep -qE "[:.]$port[[:space:]]"; then
        echo "port $port is in use; stop the listener before running the stress gate" >&2
        exit 3
      fi
    done
    dpid=; http_pid=
    cleanup() {
      trap - EXIT INT TERM
      kill $dpid $http_pid 2>/dev/null
      wait $dpid $http_pid 2>/dev/null
    }
    trap cleanup EXIT
    trap "exit 130" INT
    trap "exit 143" TERM
    mount --bind "$work/etc/passwd" /etc/passwd
    mount --bind "$work/etc/group" /etc/group
    mount --bind "$work/etc/nsswitch.conf" /etc/nsswitch.conf
    mount --bind /dev/null /var/run/nscd/socket 2>/dev/null
    mount --bind "$work/gnu-store" /gnu/store
    mount --bind "$work/var-guix" /var/guix
    mount --bind "$work/log-guix" /var/log/guix
    if test "$mode" = worktree; then
      mount --bind "$HOME" "$HOME"; chmod 755 "$HOME"
      mount --bind "$work/bin" /bin
    fi
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
  '
rc=$?
echo "stress-gate[$label] rc=$rc"
exit $rc
#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
out=${1:-$root/.scratch/hs7-restart}
cxx=${GOONIX_CXX_DAEMON:-$root/.scratch/hs0-cxx-daemon}
hs=${GOONIX_HS_DAEMON:-$root/guix-daemon}
for daemon in "$cxx" "$hs"; do test -x "$daemon"; done
pid1= pid2= scope1= scope2=
cleanup() {
  if test -n "${pid1:-}"; then goonix_stop_capped "$pid1" "${scope1:-}"; fi
  if test -n "${pid2:-}"; then goonix_stop_capped "$pid2" "${scope2:-}"; fi
}
trap cleanup EXIT

run_one() {
  name=$1 first=$2 second=$3 fixture=$out/$name
  if test -e "$fixture"; then chmod -R u+rwX "$fixture" 2>/dev/null || true; rm -rf "$fixture"; fi
  mkdir -p "$fixture/store" "$fixture/db" "$fixture/var"
  export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
  export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
  export HS7_FIXTURE="$fixture" GUIX="$root/scripts/guix"
  export GUILE_AUTO_COMPILE=0
  local daemon step pid daemon_scope
  for step in 1 2 3; do
    case "$step" in 1) daemon=$first ;; 2) daemon=$second ;; 3) daemon=$first ;; esac
    # The previous step's daemon left its socket file; remove it so the test -S
    # wait below only sees this step's daemon (a stale file would pass the wait
    # at once and race the new daemon's unlink/bind, errno 111 on the dead file).
    rm -f "$GUIX_DAEMON_SOCKET"
    test ! -e "$GUIX_DAEMON_SOCKET"
    goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon-$step.log" 2>&1
    daemon_scope=$GOONIX_TEST_SCOPE
    if test "$name" = cxx-hs-cxx; then pid1=$GOONIX_TEST_PID; scope1=$daemon_scope; else pid2=$GOONIX_TEST_PID; scope2=$daemon_scope; fi
    pid=$GOONIX_TEST_PID
    for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
    test -S "$GUIX_DAEMON_SOCKET"
    if test "$step" = 1; then
      goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/differential/restart-setup.scm"
    elif test "$step" = 2; then
      goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/differential/restart-collect.scm"
    else
      goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/differential/restart-check.scm"
    fi
    goonix_stop_capped "$pid" "$daemon_scope"
    if test "$name" = cxx-hs-cxx; then pid1=; scope1=; else pid2=; scope2=; fi
  done
  printf 'HS-7 restart %s: PASS\n' "$name"
}
mkdir -p "$out"
run_one cxx-hs-cxx "$cxx" "$hs"
run_one hs-cxx-hs "$hs" "$cxx"
# Failed runs retain their stores; successful runs retain only the step logs.
chmod -R u+rwX "$out/cxx-hs-cxx" "$out/hs-cxx-hs" 2>/dev/null || true
rm -rf "$out/cxx-hs-cxx" "$out/hs-cxx-hs"

#!/usr/bin/env bash
# Compare addNarToStore against the REAL C++ addToStoreFromDump, both driven by
# the same Guile client over the daemon socket, each in its OWN fresh store.
#
# What is easy to lose in a port (both read off nix-daemon.cc / local-store.cc):
#  - RetrieveRegularNARSink does not override isExecutable(), so for
#    recursive? = #f the executable bit of the NAR is DROPPED (writeFile 0666,
#    then canonicalise -> 0444).  Honouring the NAR bit gives 0555 and a
#    different narHash for the same input.
#  - non-recursive narHash is hashPath over the STORED path, not the declared
#    digest.
#
# Usage: add-nar.sh [CXX-DAEMON] [HS-DAEMON] [SCRATCH]
set -uo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
cd "$root" || exit 1
. "$root/daemon/test/lib.sh"
cxx=${1:-${GOONIX_CXX_DAEMON:-$root/.scratch/hs0-cxx-daemon}}
hs=${2:-${GOONIX_HS_DAEMON:-$root/guix-daemon}}
scratch=${3:-$root/.scratch/add-nar}
test -x "$cxx" || { echo "NO_CXX_DAEMON $cxx"; exit 2; }
test -x "$hs"  || { echo "NO_HS_DAEMON $hs"; exit 2; }
mkdir -p "$scratch" || exit 1

run_lane() { # lane daemon out
  local lane=$1 daemon=$2 out=$3
  # BOTH lanes use the SAME store directory string: the store prefix feeds
  # makeStorePath, so per-lane prefixes change every hash part and the diff
  # would report a difference on every fixture even where the daemons agree.
  # The lanes run one after the other into a WIPED store, so nothing is shared
  # at run time.  Sources live outside the store, per case.
  local fixture="$scratch/run"
  "$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture" || return 2
  (
    export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
    export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
    export GUIX_LOG_DIRECTORY="$fixture/var/log/guix"
    export ADD_NAR_FIXTURE="$fixture" GUILE_AUTO_COMPILE=0
    rm -f "$GUIX_DAEMON_SOCKET"
    goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot \
      --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1
    local pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
    trap 'goonix_stop_capped "$pid" "$scope"' EXIT
    local i
    for i in $(seq 1 300); do
      test -S "$GUIX_DAEMON_SOCKET" && break
      kill -0 "$pid" 2>/dev/null || break
      sleep .01
    done
    test -S "$GUIX_DAEMON_SOCKET" || { echo "NO_SOCKET $lane"; return 2; }
    goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile \
      "$root/daemon/test/differential/add-nar.scm" >"$out.raw" 2>"$out.err"
    echo "ADD_NAR_CLIENT_RC=$?"
  )
  cp "$out.raw" "$out"
  chmod -R u+rwX "$fixture" 2>/dev/null || true
}

run_lane cxx "$cxx" "$scratch/cxx.txt"
cxx_rc=$?
run_lane hs "$hs" "$scratch/hs.txt"
hs_rc=$?
echo "CXX_LANE_RC=$cxx_rc HS_LANE_RC=$hs_rc"

# An empty capture is not agreement.
if test ! -s "$scratch/cxx.txt" || test ! -s "$scratch/hs.txt"; then
  echo "EMPTY_PROBE_OUTPUT cxx=$(wc -l <"$scratch/cxx.txt" 2>/dev/null) hs=$(wc -l <"$scratch/hs.txt" 2>/dev/null)"
  tail -5 "$scratch/cxx.txt.err" "$scratch/hs.txt.err" 2>/dev/null
  exit 1
fi
# Every fixture must have reported, on both sides.
for label in flat-exec flat-plain rec-exec rec-plain flat-sha1 tree compat-fixed0; do
  for lane in cxx hs; do
    grep -q "^$label " "$scratch/$lane.txt" || { echo "MISSING_CASE $lane $label"; exit 1; }
  done
done

if diff -u "$scratch/cxx.txt" "$scratch/hs.txt" > "$scratch/diff.txt"; then
  echo "ADD_NAR_MODE_MATCH: Haskell matches C++ on every fixture"
  exit 0
fi
echo "ADD_NAR_MODE_DIFFER"
cat "$scratch/diff.txt"
exit 1
#!/usr/bin/env bash
# goonix CA-6: THE COUNTED RUN on zergling2 (reviewer, 2026-11-22).
#
# GOONIX_CA6_FRESH=1 makes the runner wipe its own store/var/log and restore the
# download seed immediately before the run, which is what makes a gate count
# (DECISIONS.md / the reviewers' "wiped and seeded store" rule).  Runs 11-13 on
# the laptop resumed a seeded store and are reported as "boots on a resumed
# store", not as this result.
#
# Download cache ON: the namespace daemon tries
# http://10.0.30.4:8480/substitutes/bordeaux first and falls back to
# https://bordeaux.guix.gnu.org, and GOONIX_DOWNLOAD_CACHE is set for the
# file-level hook (guix/download-cache.scm, 5b69dcb1f9c).
#
# Nothing here touches zergling2's private root daemon service or the Windows
# cache service itself; the cache is only read as a substitute/download URL.
set -uo pipefail
C=${1:-/home/wrath/goonix/.worktrees/goonix-implementation}
V=${2:-/tmp/z2-ca6-counted}
# The scratch tree must be OUTSIDE /tmp: the gate mounts a private tmpfs over
# /tmp for the build users, which hides everything below it - including the
# daemon's state dir, socket, log dir and the build users' home if they were
# under /tmp (measured in job ca6-z2-preflight).  Use the mirrored home.
case "$V" in /tmp/*) V="/home/wrath/z2-ca6-counted";; esac
mkdir -p "$V"
cd "$C" || exit 1
printf 'SOURCE_PATH=%s\n' "$C"
printf 'HEAD=%s\n' "$(git rev-parse HEAD 2>/dev/null)"
printf 'HOST=%s uid=%s\n' "$(hostname)" "$(id -u)"
printf 'DOWNLOAD_CACHE=%s\n' "${GOONIX_DOWNLOAD_CACHE:-http://10.0.30.4:8480}"

echo '=== build the implementation ==='
# goonix: one shared prepare step, so the laptop half of a calibration builds
# exactly like this one (reviewer, DECISIONS 37).  It bootstraps/configures only
# when needed, builds the schema header first, makes at the lane's CPU cap, and
# asserts the compiled-module precondition before returning.  -j8 here used to
# exceed zergling2's cap of 6 (the user's CPU rule).
if ! bash "$C/goonix-ca6/prepare-tree.sh" "${GOONIX_GATE_JOBS:-6}" "$C" \
     > "$V/build.log" 2>&1; then
  echo 'BUILD FAILED'; tail -n 25 "$V/build.log"; exit 1
fi
echo 'build ok'

echo '=== counted CA-6 run (FRESH: wipe + reseed, then the boot gate) ==='
export GOONIX_CA6_FRESH=1
export GOONIX_CA6_SCRATCH="$V/work"
export GOONIX_DOWNLOAD_CACHE="${GOONIX_DOWNLOAD_CACHE:-http://10.0.30.4:8480}"
nix develop '.#default' -c bash "$C/goonix-ca6/run.sh" > "$V/run.log" 2>&1
rc=$?
S="$V/work"
{
  echo "RUN_RC=$rc"
  echo "FRESH=1"
  echo "DOWNLOAD_CACHE=$GOONIX_DOWNLOAD_CACHE"
  cat "$S/policy-boot-measures" 2>/dev/null || echo NO_MEASURES
  echo "FAILED_BUILDERS=$(grep -cE 'builder for .* failed|cannot build derivation' "$S/policy-boot.err" 2>/dev/null; true)"
  echo "CACHE_LOOKUPS=$(grep -ac '10.0.30.4:8480' "$S/policy-boot.err" 2>/dev/null; true)"
  echo '--- seed restore ---'; grep -aE 'FRESH:' "$V/run.log" 2>/dev/null | head -3
  echo '--- out tail ---'; tail -n 12 "$S/policy-boot.out" 2>/dev/null
  echo '--- err tail ---'; tail -n 6 "$S/policy-boot.err" 2>/dev/null | cut -c1-200
} > "$V/counted-summary" 2>/dev/null
cat "$V/counted-summary"
cp "$V/counted-summary" /tmp/z2-ca6-counted-summary 2>/dev/null
exit "$rc"
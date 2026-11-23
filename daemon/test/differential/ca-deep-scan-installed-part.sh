#!/usr/bin/env bash
# ca-deep-scan-installed's namespace part: runs as PID 1 of the job's OWN PID
# namespace, entered by ca-deep-scan-installed.sh after the uid/gid maps and the
# bind mounts are in place.
#
# Usage (from the runner): ca-deep-scan-installed-part.sh NS ROOT DAEMON \
#   GUILE_BIN DEV_GLP DEV_GLCP PKG_GLP PKG_GLCP
set -uo pipefail
ns=${1:?ns}; root=${2:?root}; daemon=${3:?daemon}
guile_bin=${4:?guile}; dev_glp=${5:-}; dev_glcp=${6:-}
pkg_glp=${7:-}; pkg_glcp=${8:-}

# Job isolation check: refuse to start the daemon outside a private PID
# namespace (one job's build-user kill(-1) must not reach another's builders).
. "$root/daemon/test/differential/pidns-guard.sh" "ca-deep-scan" || exit 3

# env -i: GOONIX_DEEP_SCAN_HELPER is UNSET.  The daemon must find its
# installed libexec helper through the make-expanded default.
env -i TMPDIR="$ns/build" LC_ALL=C.UTF-8 PATH=/nonexistent \
  "$daemon" --build-users-group=guixbuild --max-jobs=2 --substitute-urls="" \
  > "$ns/daemon.log" 2>&1 &
dpid=$!
for i in $(seq 1 200); do test -S /var/guix/daemon-socket/socket && break; sleep 0.1; done
if ! test -S /var/guix/daemon-socket/socket; then
  echo "DAEMON DID NOT START"; head -30 "$ns/daemon.log"; kill $dpid 2>/dev/null; exit 2
fi
client_env() {
  env -i LC_ALL=C.UTF-8 PATH=/nonexistent HOME="$ns" \
    NIX_STORE_DIR=/gnu/store GUIX_STATE_DIRECTORY=/var/guix \
    GUIX_DAEMON_SOCKET=/var/guix/daemon-socket/socket \
    GUIX_DATABASE_DIRECTORY=/var/guix/db GUIX_LOG_DIRECTORY=/var/log/guix \
    GUIX_BINARY_SUBSTITUTE_URL="file://$ns/substituter-data" \
    GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES=yes \
    GUILE_LOAD_PATH="$root:$pkg_glp:$dev_glp" \
    GUILE_LOAD_COMPILED_PATH="$root:$pkg_glcp:$dev_glcp" \
    GUILE_AUTO_COMPILE=0 "$@"
}
client_env "$guile_bin" --no-auto-compile \
  "$root/daemon/test/seed-restore.scm" "/home/wrath/.cache/goonix-test-seed" \
  > "$ns/seed.log" 2>&1
echo "SEED_RC=$? $(tail -1 "$ns/seed.log")"
mkdir -p "$ns/results"
client_env "$guile_bin" --no-auto-compile -e main \
  "$root/build-aux/test-driver.scm" \
  --test-name=tests/ca-build --log-file="$ns/results/ca-build.log" \
  --trs-file="$ns/results/ca-build.trs" --brief=yes --color-tests=no \
  -- "$root/tests/ca-build.scm" > "$ns/results/ca-build.out" 2>&1
echo "CA_BUILD_RC=$?"
kill $dpid 2>/dev/null; wait $dpid 2>/dev/null
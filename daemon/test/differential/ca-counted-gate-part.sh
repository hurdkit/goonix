#!/usr/bin/env bash
# The counted CA gate's namespace part: runs as PID 1 of the job's OWN PID
# namespace, entered by ca-counted-gate.sh after the uid/gid maps are installed.
# The mounts are already in place (the caller did them before the pid unshare).
#
# Usage (from the runner): ca-counted-gate-part.sh NS ROOT DAEMON LABEL \
#   GUILE_BIN DEV_GLP DEV_GLCP PKG_GLP PKG_GLCP FIXTURE SLIRP_BIN SUITES
set -uo pipefail
ns=${1:?ns}; root=${2:?root}; daemon=${3:?daemon}; label=${4:?label}
guile_bin=${5:?guile}; dev_glp=${6:-}; dev_glcp=${7:-}
pkg_glp=${8:-}; pkg_glcp=${9:-}; fixture=${10:-}
slirp_bin=${11:-}; suites=${12:?suites}

# Job isolation check: refuse to start the daemon outside a private PID
# namespace.  A daemon kills all of a build user's processes before a build and
# the build-user uids come from the host range, so a shared namespace lets one
# job's kill(-1) reach another job's builders.
. "$root/daemon/test/differential/pidns-guard.sh" "$label" || exit 3

# The installed daemon as namespace root: chroot ON (default), build users,
# env -i (only TMPDIR/LC_ALL/PATH=/nonexistent).  No GUIX_*/GUILE_*, no
# --no-offload: the package finds its own helpers and sandbox.
# GUIX_SLIRP4NETNS: the HS daemon resolves slirp4netns via findExecutable
# (PATH), which is /nonexistent here; point it at the dev-shell binary so
# fixed-output builds get network access (C++ uses its baked absolute path).
# GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES: the daemon spawns the guix
# substitute helper inheriting ITS environment, so the file:// test cache
# is only accepted as a substitute URI when the DAEMON (not just the
# client) allows unsafe URIs.
env -i TMPDIR="$ns/build" LC_ALL=C.UTF-8 PATH=/nonexistent \
  GUIX_SLIRP4NETNS="$slirp_bin" \
  GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES=yes \
  GUIX_STATE_DIRECTORY=/var/guix \
  "$daemon" --build-users-group=guixbuild --max-jobs=2 --substitute-urls="" \
  > "$ns/daemon.log" 2>&1 &
dpid=$!
for i in $(seq 1 200); do test -S /var/guix/daemon-socket/socket && break; sleep 0.1; done
if ! test -S /var/guix/daemon-socket/socket; then
  echo "DAEMON DID NOT START ($label)"; head -20 "$ns/daemon.log"; kill $dpid 2>/dev/null; exit 2
fi
# Client environment: the WORKTREE first on the load path (exactly as
# pre-inst-env: builddir:srcdir:$GUILE_LOAD_PATH), then the installed
# package modules, then dev-shell deps.  Worktree-first is required so
# gnu/packages/bootstrap.scm resolves from the worktree, where the
# gitignored bootstrap binaries (bash/mkdir) live; the package ships no
# bootstrap dir and is read-only, so search-bootstrap-binary would try to
# write the built binary into the nix store and fail.  The daemon under
# test is still the INSTALLED package; only the client modules load this
# way.  NIX_STORE_DIR=/gnu/store matches the daemon; the socket is the
# configure-time /var/guix/daemon-socket/socket.
client_env() {
  env -i LC_ALL=C.UTF-8 PATH=/nonexistent HOME="$ns" \
    NIX_STORE_DIR=/gnu/store \
    GUIX_STATE_DIRECTORY=/var/guix \
    GUIX_DAEMON_SOCKET=/var/guix/daemon-socket/socket \
    GUIX_DATABASE_DIRECTORY=/var/guix/db \
    GUIX_LOG_DIRECTORY=/var/log/guix \
    GUIX_BINARY_SUBSTITUTE_URL="file://$ns/substituter-data" \
    GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES=yes \
    GOONIX_SCAN_REAL_STORE="$fixture" \
    GUILE_LOAD_PATH="$root:$pkg_glp:$dev_glp" \
    GUILE_LOAD_COMPILED_PATH="$root:$pkg_glcp:$dev_glcp" \
    GUILE_AUTO_COMPILE=0 \
    "$@"
}
# Seed the fresh store (bootstrap binaries + downloads).  The seed lives
# at the caller absolute cache path (HOME inside the ns is the scratch).
client_env "$guile_bin" --no-auto-compile \
  "$root/daemon/test/seed-restore.scm" "/home/wrath/.cache/goonix-test-seed" \
  > "$ns/seed.log" 2>&1
echo "SEED_RC_${label}=$? $(tail -1 "$ns/seed.log")"
mkdir -p "$ns/results"
for name in $suites; do
  client_env "$guile_bin" --no-auto-compile -e main \
    "$root/build-aux/test-driver.scm" \
    --test-name="tests/$name" --log-file="$ns/results/$name.log" \
    --trs-file="$ns/results/$name.trs" --brief=yes --color-tests=no \
    -- "$root/tests/$name.scm" > "$ns/results/$name.out" 2>&1
  rc=$?
  pass=$(grep -c ":test-result: PASS" "$ns/results/$name.trs" 2>/dev/null || echo 0)
  fail=$(grep -c ":test-result: FAIL" "$ns/results/$name.trs" 2>/dev/null || echo 0)
  skip=$(grep -c ":test-result: SKIP" "$ns/results/$name.trs" 2>/dev/null || echo 0)
  err=$(grep -c ":test-result: ERROR" "$ns/results/$name.trs" 2>/dev/null || echo 0)
  printf "%s %-18s rc=%s pass=%s fail=%s skip=%s error=%s\n" "$label" "$name" "$rc" "$pass" "$fail" "$skip" "$err"
done
kill $dpid 2>/dev/null; wait $dpid 2>/dev/null
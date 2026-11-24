#!/usr/bin/env bash
# root-ci's namespace part: runs as PID 1 of the job's OWN PID namespace,
# entered by root-ci.sh after the uid/gid maps and the bind mounts are in place.
#
# Usage (from the runner): root-ci-part.sh WORK ROOT DAEMON MODE GITREV \
#   PAYLOAD_HASH GIT_HASH DEV_GLP DEV_GLCP ROOT_CI_CLIENT SOCAT_BIN GIT_BIN
set -uo pipefail
work=${1:?work}; root=${2:?root}; daemon=${3:?daemon}; mode=${4:?mode}
gitrev=${5:?gitrev}; payload_hash=${6:?payload}; git_hash=${7:?git}
dev_glp=${8:-}; dev_glcp=${9:-}; ROOT_CI_CLIENT=${10:-}
# Absolute fixture-tool paths the runner resolved in the DEV SHELL.  Bare
# `socat'/`git' here depended on whatever PATH the host gave the job: without
# socat the HTTP fixture never started and builtin:download failed with
# "Connection refused", which read as a daemon defect.  The runner refuses to
# start when either is missing, so these are non-empty by construction.
socat_bin=${11:?socat path from the runner}; git_bin=${12:?git path from the runner}

# Job isolation check: refuse to start the daemon outside a private PID
# namespace (one job's build-user kill(-1) must not reach another's builders).
. "$root/daemon/test/differential/pidns-guard.sh" "root-ci" || exit 3

# Local servers for the builtins (they refuse file:// URLs): HTTP for
# builtin:download, git:// for builtin:git-download.  Loopback is shared
# with the host (no network namespace), so the daemon reaches them.
"$socat_bin" TCP-LISTEN:18080,reuseaddr,fork \
  EXEC:"$root/daemon/test/differential/root-ci-http.sh $work/payload.txt" \
  > "$work/http.log" 2>&1 &
http_pid=$!
"$git_bin" daemon --base-path="$work/gitrepo" --export-all --reuseaddr \
  --listen=127.0.0.1 --port=19418 "$work/gitrepo" > "$work/gitd.log" 2>&1 &
gitd_pid=$!
sleep 1
# Daemon as namespace root: chroot ON (default), build users, env -i.
# installed (CI-like): only TMPDIR, LC_ALL and PATH=/nonexistent - nothing
# the runner does not have.  No GUIX_SANDBOX / GUILE_* / GUIX_UNINSTALLED,
# no --no-offload: the package must locate its own guix helpers and sandbox.
# worktree: the build-tree daemon needs the guile load paths (its helpers
# load build-tree modules), GUIX_SANDBOX and --no-offload to run uninstalled.
if test "$mode" = worktree; then
  env -i TMPDIR="$work/build" LC_ALL=C.UTF-8 PATH=/nonexistent \
    GUILE_LOAD_PATH="$root:$dev_glp" GUILE_LOAD_COMPILED_PATH="$root:$dev_glcp" GUIX_UNINSTALLED=1 \
    GUIX_SANDBOX="$root/guix-sandbox" \
    "$daemon" --build-users-group=guixbuild --max-jobs=2 --substitute-urls="" --no-offload \
    > "$work/daemon.log" 2>&1 &
else
  env -i TMPDIR="$work/build" LC_ALL=C.UTF-8 PATH=/nonexistent \
    "$daemon" --build-users-group=guixbuild --max-jobs=2 --substitute-urls="" \
    > "$work/daemon.log" 2>&1 &
fi
dpid=$!
for i in $(seq 1 200); do test -S /var/guix/daemon-socket/socket && break; sleep 0.1; done
if ! test -S /var/guix/daemon-socket/socket; then
  echo "DAEMON DID NOT START"; head -20 "$work/daemon.log"; kill $dpid 2>/dev/null; exit 2
fi
# Client WITHOUT GUIX_LOG_DIRECTORY (GUILE_LOAD_PATH only locates modules).
# ROOT_CI_CLIENT overrides the client script (default: the 6-case CI gate);
# the killUser reproduction client takes WORK-DIR and ignores the rest.
client=${ROOT_CI_CLIENT:-$root/daemon/test/differential/root-ci-client.scm}
env -i LC_ALL=C.UTF-8 PATH=/nonexistent \
  GUILE_LOAD_PATH="$root:$dev_glp" GUILE_LOAD_COMPILED_PATH="$root:$dev_glcp" GUIX_UNINSTALLED=1 \
  "$root/guile" --no-auto-compile "$client" \
  "$work" "$gitrev" "$payload_hash" "$git_hash"
rc=$?
kill $dpid $http_pid $gitd_pid 2>/dev/null; wait $dpid 2>/dev/null
exit $rc
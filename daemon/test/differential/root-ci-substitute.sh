#!/usr/bin/env bash
# goonix: substituter regressions inside the root-ci namespace (reviewer point 2).
# Runs as namespace ROOT with the bind-mounted scratch store, build users and
# chroot available, against the INSTALLED package daemon under test.  Starts a
# daemon whose substitute helper is a fake (GUIX override) and runs both
# substituter regressions:
#   - substitute-log-flood: the helper floods the log pipe (>64 KiB) before its
#     reply; the daemon must drain it and answer (52fe97d8ec7).
#   - substitute-silent: the helper stays silent before its reply while a second
#     client runs allocating queries; the daemon must keep serving (b79edc950f1,
#     IO-manager wait, small -A so the GC runs).
# Both must PASS.  Called from root-ci.sh inside the unshare namespace; the
# caller has already bind-mounted /gnu/store, /var/guix, /var/log/guix, /etc.
#
# Usage: root-ci-substitute.sh DAEMON WORK ROOT DEV_GLP DEV_GLCP
set -uo pipefail
daemon=${1:?daemon}; work=${2:?work}; root=${3:?root}
dev_glp=${4:-}; dev_glcp=${5:-}
here="$root/daemon/test/differential"
sub="$work/substitute"
mkdir -p "$sub/store" "$sub/db" "$sub/var" "$sub/log" "$sub/etc" "$sub/cache" "$sub/tmp"
sqlite3 "$sub/db/db.sqlite" < "$root/guix/store/schema.sql"
printf 7 > "$sub/db/schema"

start_daemon() { # helper rts-args...
  local helper=$1; shift
  env -i TMPDIR="$sub/tmp" LC_ALL=C.UTF-8 PATH=/nonexistent GUIX="$helper" \
    NIX_STORE_DIR="$sub/store" GUIX_DATABASE_DIRECTORY="$sub/db" \
    GUIX_STATE_DIRECTORY="$sub/var" GUIX_LOG_DIRECTORY="$sub/log" \
    GUIX_DAEMON_SOCKET="$sub/socket" \
    "$daemon" --build-users-group=guixbuild --max-jobs=2 --substitute-urls="" \
    --listen="$sub/socket" "$@" >"$sub/daemon.log" 2>&1 &
  dpid=$!
  local i
  for i in $(seq 1 300); do test -S "$sub/socket" && break; kill -0 "$dpid" 2>/dev/null || break; sleep .05; done
  test -S "$sub/socket"
}
stop_daemon() { kill "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null; rm -f "$sub/socket"; }

run_client() { # script logfile
  env -i LC_ALL=C.UTF-8 PATH=/nonexistent \
    NIX_STORE_DIR="$sub/store" GUIX_DATABASE_DIRECTORY="$sub/db" \
    GUIX_STATE_DIRECTORY="$sub/var" GUIX_LOG_DIRECTORY="$sub/log" \
    GUIX_DAEMON_SOCKET="$sub/socket" XDG_CACHE_HOME="$sub/cache" \
    GUILE_LOAD_PATH="$root:$dev_glp" GUILE_LOAD_COMPILED_PATH="$root:$dev_glcp" GUIX_UNINSTALLED=1 \
    SILENT_SECONDS="${SILENT_SECONDS:-8}" BUSY_ITERATIONS="${BUSY_ITERATIONS:-400}" \
    "$root/guile" --no-auto-compile "$1" >"$2" 2>&1
}

rc=0
# --- 1. log-flood: drain the flooded log pipe and answer ---
chmod +x "$here/substitute-log-flood-helper.sh"
if start_daemon "$here/substitute-log-flood-helper.sh"; then
  if run_client "$here/substitute-log-flood.scm" "$sub/flood.log" && grep -q 'substitute-log-drain: PASS' "$sub/flood.log"; then
    echo "root-ci substitute-log-flood: PASS"
  else
    echo "root-ci substitute-log-flood: FAIL"; tail -5 "$sub/flood.log"; rc=1
  fi
  stop_daemon
else
  echo "root-ci substitute-log-flood: FAIL (daemon did not start)"; tail -5 "$sub/daemon.log"; rc=1
fi

# --- 2. silent: keep serving while the helper is silent (small -A forces GC) ---
chmod +x "$here/substitute-silent-helper.sh"
if start_daemon "$here/substitute-silent-helper.sh" +RTS -A"${RTS_A:-1m}" -N -RTS; then
  if run_client "$here/substitute-silent.scm" "$sub/silent.log" && grep -q 'substitute-silent-wait: PASS' "$sub/silent.log"; then
    echo "root-ci substitute-silent: PASS"
  else
    echo "root-ci substitute-silent: FAIL"; tail -5 "$sub/silent.log"; rc=1
  fi
  stop_daemon
else
  echo "root-ci substitute-silent: FAIL (daemon did not start)"; tail -5 "$sub/daemon.log"; rc=1
fi

exit $rc
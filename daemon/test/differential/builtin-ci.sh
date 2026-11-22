#!/usr/bin/env bash
# goonix: builtin download/git-download under a CI-like daemon (HS-8 switch-2).
# The CI runner starts the daemon with `systemd-run --setenv=TMPDIR=…
# --setenv=LC_ALL=…`, so there is no GUIX and no guix on PATH.  The daemon must
# resolve the guix program via NIX_BIN_DIR / the configured bindir, never PATH.
# Each daemon is started with `env -i TMPDIR=… LC_ALL=C.UTF-8 PATH=/nonexistent`
# (no GUIX).  Two resolution modes are exercised: nixbindir sets NIX_BIN_DIR to
# the real guix bindir; bindir leaves NIX_BIN_DIR unset so the daemon falls back
# to its CONFIGURED bindir + /guix (the CI runner's path).  The bindir mode runs
# only for an installed package whose own bindir holds guix, and is skipped
# (saying so) for a worktree build whose prefix has no guix.  A client builds
# builtin:download + builtin:git-download and checks that a failing builtin
# build leaves a log `guix build --log-file' finds.
# Calibrated: 2caf36817f4's Haskell daemon (literal "guix" PATH fallback) fails.
set -u
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
cxx=${GOONIX_CXX_DAEMON:-$root/.scratch/hs0-cxx-daemon}
hs=${GOONIX_HS_DAEMON:-$root/guix-daemon}
out=${1:-/tmp/gx-builtin-ci}
for daemon in "$cxx" "$hs"; do test -x "$daemon"; done
rm -rf "$out"; mkdir -p "$out"
guixbin=$(dirname "$(command -v guix)")
test -x "$guixbin/guix" || { echo "no guix on the test host PATH" >&2; exit 2; }

run_one() {
  name=$1 daemon=$2 mode=${3:-nixbindir}
  base=$out/$name
  mkdir -p "$base/store" "$base/db" "$base/var" "$base/log" "$base/tmp"
  sqlite3 "$base/db/db.sqlite" < "$root/guix/store/schema.sql"
  # CI-like environment: no GUIX, no guix on PATH.  In nixbindir mode NIX_BIN_DIR
  # is the resolved bindir the fixed daemon uses; the old daemon ignores it and
  # searches PATH.  In bindir mode NIX_BIN_DIR is unset, so the daemon must fall
  # back to its CONFIGURED bindir + /guix — the path the CI runner takes.
  if test "$mode" = nixbindir; then
    env -i TMPDIR="$base/tmp" LC_ALL=C.UTF-8 PATH=/nonexistent NIX_BIN_DIR="$guixbin" \
      NIX_STORE_DIR="$base/store" GUIX_DATABASE_DIRECTORY="$base/db" \
      GUIX_STATE_DIRECTORY="$base/var" GUIX_LOG_DIRECTORY="$base/log" \
      GUIX_DAEMON_SOCKET="$base/var/socket" \
      "$daemon" --disable-chroot --listen="$base/var/socket" >"$base/daemon.log" 2>&1 &
  else
    env -i TMPDIR="$base/tmp" LC_ALL=C.UTF-8 PATH=/nonexistent \
      NIX_STORE_DIR="$base/store" GUIX_DATABASE_DIRECTORY="$base/db" \
      GUIX_STATE_DIRECTORY="$base/var" GUIX_LOG_DIRECTORY="$base/log" \
      GUIX_DAEMON_SOCKET="$base/var/socket" \
      "$daemon" --disable-chroot --listen="$base/var/socket" >"$base/daemon.log" 2>&1 &
  fi
  pid=$!
  for i in $(seq 1 300); do test -S "$base/var/socket" && break; kill -0 "$pid" 2>/dev/null || break; sleep .05; done
  if ! test -S "$base/var/socket"; then
    echo "FAIL: $name: daemon did not start"; tail -3 "$base/daemon.log" >&2
    return 1
  fi
  # The client has guix on PATH (pre-inst-env); it talks to the CI-like daemon.
  ( cd "$root" && GUIX_DAEMON_SOCKET="$base/var/socket" NIX_STORE_DIR="$base/store" \
    GUIX_DATABASE_DIRECTORY="$base/db" GUIX_STATE_DIRECTORY="$base/var" \
    GUIX_LOG_DIRECTORY="$base/log" XDG_CACHE_HOME="$base/cache" \
    ./pre-inst-env guile --no-auto-compile "$root/daemon/test/differential/builtin-ci.scm" ) \
    >"$base/client.log" 2>&1
  rc=$?
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  chmod -R u+rwX "$base" 2>/dev/null
  if test "$rc" -eq 0; then
    echo "PASS: $name ($(grep -o 'download-ok=[^ ]* git-download-ok=[^ ]* failing-log-found=[^ ]*' "$base/client.log" | head -1))"
  else
    echo "FAIL: $name"
    grep -E 'download-ok=|ERROR|error|failed|Unbound' "$base/client.log" | head -5 >&2
  fi
  return "$rc"
}

status=0
run_one cxx "$cxx" || status=1
run_one hs "$hs" || status=1
# The configured-bindir fallback (no NIX_BIN_DIR) is the path the CI runner
# takes.  For an INSTALLED package (in the nix store) whose own bindir holds guix,
# run it directly.  A worktree build's configured bindir (/bin) has no guix on this
# host; to exercise the fallback for it, pass an installed package built from the
# tree via GOONIX_INSTALLED_PKG (its bin must hold guix + guix-daemon) and the
# fallback runs against THAT daemon.  Without it the fallback is skipped, saying
# so.  A daemon that searches PATH (the 9a3d3c08528 calibration, literal "guix")
# fails this; the configured-bindir resolution passes.
bindir_fallback() {
  label=$1 daemon=$2
  dbin=$(dirname "$daemon")
  case "$daemon" in
    /nix/store/*) installed=1 ;;
    *) installed=0 ;;
  esac
  if test "$installed" = 1 && test -x "$dbin/guix"; then
    run_one "$label-bindir" "$daemon" bindir || status=1
    return
  fi
  # Worktree build: an installed package supplied via GOONIX_INSTALLED_PKG lets
  # the configured-bindir fallback run without a heavy in-test package build.
  # Only the Haskell daemon is installed from this tree; the C++ reference is a
  # worktree build with no installed package, so its fallback stays skipped.
  if test "$label" = hs && test -n "${GOONIX_INSTALLED_PKG:-}" \
     && test -x "$GOONIX_INSTALLED_PKG/bin/guix" \
     && test -x "$GOONIX_INSTALLED_PKG/bin/guix-daemon"; then
    run_one "$label-bindir" "$GOONIX_INSTALLED_PKG/bin/guix-daemon" bindir || status=1
    return
  fi
  echo "SKIP: $label-bindir: no installed package with guix in its bindir (set GOONIX_INSTALLED_PKG to a package built from the tree to exercise the configured-bindir fallback for a worktree build)"
}
bindir_fallback cxx "$cxx"
bindir_fallback hs "$hs"
if test "$status" -eq 0; then echo "builtin CI differential: PASS"; else echo "builtin CI differential: FAIL" >&2; fi
exit "$status"
#!/usr/bin/env bash
# PR #6 CI-like regression runner.  Two daemon modes:
#   installed (default) - the CI-like one.  The daemon under test is an installed
#     package: env -i gives it only TMPDIR, LC_ALL and PATH=/nonexistent, exactly
#     what the runner gives it.  No GUIX_SANDBOX, GUILE_LOAD_PATH,
#     GUILE_LOAD_COMPILED_PATH or GUIX_UNINSTALLED, no /bin bind-mount, no
#     --no-offload, and the caller's home directory is left untouched.  This is
#     what the package must find by itself; the worktree conveniences below let a
#     build-tree daemon pass and hide a package that cannot.
#   worktree (ROOT_CI_MODE=worktree) - the build-tree daemon, with the guile load
#     paths, GUIX_SANDBOX, the /bin bind-mount and --no-offload it needs to run
#     uninstalled.  Kept for build-tree testing only; NOT the CI-like mode.
# Runs root-ci-setup.sh, then the daemon as namespace root (chroot ON,
# --build-users-group), then the root-ci-client.scm checks.  No sudo; the NixOS
# setuid newuidmap/newgidmap wrappers must be first in PATH.
#
# Usage: root-ci.sh DAEMON [LABEL]
set -uo pipefail
daemon=${1:?usage: root-ci.sh DAEMON [LABEL]}
label=${2:-$(basename "$daemon")}
mode=${ROOT_CI_MODE:-installed}
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
here="$root/daemon/test/differential"
work=/tmp/pr6-root-ci/$label
uid=$(id -u)
gid=$(id -g)

# Deterministic no-root/no-store regressions first, so every pin move runs them
# before any daemon is started.  A failure here stops the run naming the test.
# Run them through the dev shell as the devinfo step below does: sqlite-contention
# compiles the daemon's Database.hs with ghc, which is only on PATH inside
# `nix develop`.  A missing compiler stays a FAIL (sqlite-contention.sh exits 2 on
# "no ghc"); it must never turn into a silent pass.
(cd "$root" && nix develop "$root#default" -c bash "$here/regressions.sh" "$root") || exit 1
# --- fixture-tool preflight, BEFORE anything is set up or started ---
# root-ci-part.sh runs `socat TCP-LISTEN' for builtin:download and `git daemon'
# for builtin:git-download.  Taking them from the host PATH made the gate depend
# on the machine: on zergling2 socat was absent, the HTTP fixture never started,
# and the builder's "Connection refused" was reported as a daemon FAIL.  Resolve
# them in the DEV SHELL (flake.nix provides socat and git) and refuse to run at
# all when either is missing, the same way the pidns guard refuses with exit 3.
fixture_tools=$(cd "$root" && nix develop .#default -c bash -c '
  for t in socat git; do
    p=$(command -v "$t" 2>/dev/null) || p=
    printf "%s=%s\n" "$t" "$p"
  done')
socat_bin=$(printf '%s\n' "$fixture_tools" | sed -n 's/^socat=//p')
git_bin=$(printf '%s\n' "$fixture_tools" | sed -n 's/^git=//p')
for pair in "socat:$socat_bin" "git:$git_bin"; do
  tool=${pair%%:*}
  path=${pair#*:}
  if test -z "$path" || test ! -x "$path"; then
    echo "root-ci: MISSING FIXTURE TOOL $tool (not in the dev shell); refusing to run a gate whose fixture cannot start" >&2
    exit 3
  fi
done
echo "fixture tools: socat=$socat_bin git=$git_bin"

bash "$here/root-ci-setup.sh" "$daemon" "$label" || exit 1
daemon=$(readlink -f "$daemon")
gitrev=$(cat "$work/gitrev")

# Compute the payload + git hashes in the dev shell (build-tree guile modules),
# and capture the dev-shell GUILE_LOAD_PATH (guile-gcrypt, guile-git, ... live in
# the nix store, not the build tree) so the namespace client can load modules.
devinfo=$(cd "$root" && nix develop .#default -c bash -c 'guile --no-auto-compile -L . -c "(use-modules (guix hash) (guix base32) (gcrypt hash) (rnrs io ports)) (display (bytevector->nix-base32-string (sha256 (call-with-input-file \"'"$work"'/payload.txt\" get-bytevector-all)))) (newline) (display (bytevector->nix-base32-string (file-hash* \"'"$work"'/gitrepo\" #:algorithm (hash-algorithm sha256) #:recursive? #t))) (newline)"; echo "GLP=$GUILE_LOAD_PATH"; echo "GLCP=$GUILE_LOAD_COMPILED_PATH"')
payload_hash=$(echo "$devinfo" | sed -n 1p)
git_hash=$(echo "$devinfo" | sed -n 2p)
dev_glp=$(echo "$devinfo" | grep '^GLP=' | sed 's/^GLP=//')
dev_glcp=$(echo "$devinfo" | grep '^GLCP=' | sed 's/^GLCP=//')
echo "payload_hash=$payload_hash git_hash=$git_hash gitrev=$gitrev"

export PATH=/run/wrappers/bin:$PATH
timeout 300 unshare --user \
  --map-users=0:"$uid":1 --map-users=1:100000:65536 \
  --map-groups=0:"$gid":1 --map-groups=1:100000:65536 \
  --mount -- bash -c '
    set -uo pipefail
    work="'"$work"'"; root="'"$root"'"; daemon="'"$daemon"'"; mode="'"$mode"'"
    gitrev="'"$gitrev"'"; payload_hash="'"$payload_hash"'"; git_hash="'"$git_hash"'"
    dev_glp="'"$dev_glp"'"; dev_glcp="'"$dev_glcp"'"; ROOT_CI_CLIENT="'"${ROOT_CI_CLIENT:-}"'"
    socat_bin="'"$socat_bin"'"; git_bin="'"$git_bin"'"
    # Fail fast if a server port is already taken: a busy port must not turn into
    # a FAIL of a download check (the daemon would talk to the wrong server).
    # Loopback is shared with the host, so ss sees host listeners here too.
    for port in 18080 19418; do
      if ss -ltn 2>/dev/null | grep -qE "[:.]$port[[:space:]]"; then
        echo "port $port is in use; stop the listener before running root-ci" >&2
        exit 3
      fi
    done
    # Cleanup on EVERY exit (normal, early exit, or a caught signal): stop the
    # daemon, socat and git-daemon.  git daemon forks a git-daemon child that
    # outlives its parent, so kill any child matching the base-path of this run.
    dpid=; http_pid=; gitd_pid=
    cleanup() {
      trap - EXIT INT TERM
      kill $dpid $http_pid $gitd_pid 2>/dev/null
      pkill -f "git-daemon --base-path=$work/gitrepo" 2>/dev/null
      pkill -f "git daemon --base-path=$work/gitrepo" 2>/dev/null
      wait $dpid $http_pid $gitd_pid 2>/dev/null
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
      # Build-tree daemon only: the build user must traverse the caller home
      # (mode 700) to reach the build-tree guile the builtin spawns, and /bin
      # must hold guix + sh.  Bind-mount the home onto itself and relax the mode
      # in the namespace only (the host inode is unchanged).  The installed
      # (CI-like) mode does none of this: the package finds its own helpers.
      mount --bind "$HOME" "$HOME"
      chmod 755 "$HOME"
      mount --bind "$work/bin" /bin
    fi
    # Job isolation: the uid/gid maps are installed, so enter a PRIVATE PID
    # namespace before the daemon starts.  A daemon kills every process of a
    # build user before a build and those uids come from the host range, so
    # without this the kill(-1) of one job reaches the builders of another.
    # Absolute bash: worktree mode bind-mounts a scratch /bin over /bin, which
    # hides /bin/bash on a merged-usr host (WSL: the real one is /usr/bin/bash).
    # root-ci-setup.sh links the real bash into that scratch /bin; prefer the
    # absolute path of the running shell when it is not under the hidden /bin.
    part_bash=$BASH
    case "$part_bash" in /bin/*) part_bash=$(command -v bash) ;; esac
    exec unshare --pid --fork --kill-child -- "$part_bash" "$0" "$@"
  ' "$here/root-ci-part.sh" "$work" "$root" "$daemon" "$mode" "$gitrev" \
    "$payload_hash" "$git_hash" "$dev_glp" "$dev_glcp" "${ROOT_CI_CLIENT:-}" \
    "$socat_bin" "$git_bin"
rc=$?
echo "root-ci[$label] rc=$rc"
exit $rc
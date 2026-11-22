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
    # Local servers for the builtins (they refuse file:// URLs): HTTP for
    # builtin:download, git:// for builtin:git-download.  Loopback is shared
    # with the host (no network namespace), so the daemon reaches them.
    socat TCP-LISTEN:18080,reuseaddr,fork \
      EXEC:"$root/daemon/test/differential/root-ci-http.sh $work/payload.txt" \
      > "$work/http.log" 2>&1 &
    http_pid=$!
    git daemon --base-path="$work/gitrepo" --export-all --reuseaddr \
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
    exit $rc   # the EXIT trap stops the daemon, socat and git-daemon
  '
rc=$?
echo "root-ci[$label] rc=$rc"
exit $rc
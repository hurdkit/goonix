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
    "$payload_hash" "$git_hash" "$dev_glp" "$dev_glcp" "${ROOT_CI_CLIENT:-}"
rc=$?
echo "root-ci[$label] rc=$rc"
exit $rc
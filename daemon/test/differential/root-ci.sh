#!/usr/bin/env bash
# PR #6 CI-like regression runner (reviewer mail m21bc93f58d74404f, item 3).
# Runs root-ci-setup.sh, then the daemon as namespace root (chroot ON,
# --build-users-group, env -i, no GUIX/NIX_BIN_DIR/GUIX_LOG_DIRECTORY), then the
# root-ci-client.scm checks.  No sudo; the NixOS setuid newuidmap/newgidmap
# wrappers must be first in PATH.
#
# Usage: root-ci.sh DAEMON [LABEL]
set -uo pipefail
daemon=${1:?usage: root-ci.sh DAEMON [LABEL]}
label=${2:-$(basename "$daemon")}
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
here="$root/daemon/test/differential"
work=/tmp/pr6-root-ci/$label

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
  --map-users=0:1000:1 --map-users=1:100000:65536 \
  --map-groups=0:100:1 --map-groups=1:100000:65536 \
  --mount -- bash -c '
    set -uo pipefail
    work="'"$work"'"; root="'"$root"'"; daemon="'"$daemon"'"
    gitrev="'"$gitrev"'"; payload_hash="'"$payload_hash"'"; git_hash="'"$git_hash"'"
    dev_glp="'"$dev_glp"'"; dev_glcp="'"$dev_glcp"'"
    mount --bind "$work/etc/passwd" /etc/passwd
    mount --bind "$work/etc/group" /etc/group
    mount --bind "$work/etc/nsswitch.conf" /etc/nsswitch.conf
    mount --bind /dev/null /var/run/nscd/socket 2>/dev/null
    # The build user must traverse /home/wrath (mode 700) to reach the build-tree
    # guile the builtin spawns.  Bind-mount it onto itself and relax the mode in
    # the namespace only (the host inode is unchanged).
    mount --bind /home/wrath /home/wrath
    chmod 755 /home/wrath
    mount --bind "$work/gnu-store" /gnu/store
    mount --bind "$work/var-guix" /var/guix
    mount --bind "$work/log-guix" /var/log/guix
    mount --bind "$work/bin" /bin
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
    # Daemon as namespace root: chroot ON (default), build users, env -i,
    # no GUIX / NIX_BIN_DIR / GUIX_LOG_DIRECTORY.  GUILE_LOAD_PATH is kept so the
    # guix helpers the daemon spawns (perform-download, authenticate) can load
    # their modules; --no-offload keeps the build local (no offload hook).
    env -i TMPDIR="$work/build" LC_ALL=C.UTF-8 PATH=/nonexistent \
      GUILE_LOAD_PATH="$root:$dev_glp" GUILE_LOAD_COMPILED_PATH="$root:$dev_glcp" GUIX_UNINSTALLED=1 \
      GUIX_SANDBOX="$root/guix-sandbox" \
      "$daemon" --build-users-group=guixbuild --max-jobs=2 --substitute-urls="" --no-offload \
      > "$work/daemon.log" 2>&1 &
    dpid=$!
    for i in $(seq 1 200); do test -S /var/guix/daemon-socket/socket && break; sleep 0.1; done
    if ! test -S /var/guix/daemon-socket/socket; then
      echo "DAEMON DID NOT START"; head -20 "$work/daemon.log"; kill $dpid 2>/dev/null; exit 2
    fi
    # Client WITHOUT GUIX_LOG_DIRECTORY (GUILE_LOAD_PATH only locates modules).
    env -i LC_ALL=C.UTF-8 PATH=/nonexistent \
      GUILE_LOAD_PATH="$root:$dev_glp" GUILE_LOAD_COMPILED_PATH="$root:$dev_glcp" GUIX_UNINSTALLED=1 \
      "$root/guile" --no-auto-compile "$root/daemon/test/differential/root-ci-client.scm" \
      "$work" "$gitrev" "$payload_hash" "$git_hash"
    rc=$?
    kill $dpid $http_pid $gitd_pid 2>/dev/null; wait $dpid 2>/dev/null
    exit $rc
  '
rc=$?
echo "root-ci[$label] rc=$rc"
exit $rc
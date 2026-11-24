#!/usr/bin/env bash
# PR #6 CI-like regression setup.
# Run a daemon as ROOT inside a user namespace with real build users, chroot ON,
# env -i (no GUIX/NIX_BIN_DIR/GUIX_LOG_DIRECTORY), then:
#   - build a builtin:download and a builtin:git-download;
#   - build one ordinary derivation in the chroot;
#   - check a client WITHOUT GUIX_LOG_DIRECTORY finds a failing build's log
#     with `guix build --log-file`.
# Both daemons must pass; the f65f695 Haskell daemon must FAIL (calibration).
#
# No sudo.  util-linux unshare maps the caller's uid->ns root(0) and the
# subordinate range 100000:65536 -> 1:65536.  The NixOS setuid WRAPPER
# newuidmap/newgidmap (/run/wrappers/bin) must be FIRST in PATH (the store binary
# is not setuid -> "write to uid_map failed: Operation not permitted").  nscd is
# masked so NSS reads the bind-mounted passwd/group.  /gnu/store, /var/guix,
# /var/log/guix, /etc/{passwd,group,nsswitch.conf} are bind-mounted scratch paths
# so the daemon (Config.storeDirectory=/gnu/store, Config.logDirectory=/var/log/guix)
# and the build-tree client (config.scm %storedir=/gnu/store, %localstatedir=/var)
# agree without any GUIX_* environment.
#
# Usage: root-ci.sh DAEMON [LABEL]
set -uo pipefail
daemon=${1:?usage: root-ci.sh DAEMON [LABEL]}
label=${2:-$(basename "$daemon")}
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
work=/tmp/pr6-root-ci/$label
# Store items are read-only (dirs 0555), so `rm -rf` alone cannot unlink their
# entries: it fails EACCES per file and leaves the previous run's store standing
# while the script goes on to seed and test it.  The counted gate hit exactly
# this (see ca-counted-gate.sh setup_ns).  Labels here are reused across runs, so
# make the tree writable first and refuse to continue on a leftover store.
if test -e "$work"; then
  chmod -R u+rwX "$work" 2>/dev/null || true
  rm -rf "$work"
  if test -e "$work"; then
    echo "root-ci setup FAILED: could not clear $work; refusing to test a leftover store" >&2
    exit 1
  fi
fi
mkdir -p "$work"/{gnu-store,var-guix,log-guix,etc,build,bin,cache,gitrepo,substituter-data}
mkdir -p "$work/var-guix"/{db,gcroots,profiles,temproots,daemon-socket}

# --- build users in the mapped subordinate range (inner 30001.. -> outer 130001..) ---
{
  printf 'root:x:0:0:root:/root:/bin/sh\n'
  printf 'nobody:x:65534:65534:nobody:/var/empty:/bin/sh\n'
  printf 'guixbuilder01:x:30001:30000:Guix build user 1:/var/empty:/bin/sh\n'
  printf 'guixbuilder02:x:30002:30000:Guix build user 2:/var/empty:/bin/sh\n'
  printf 'guixbuilder03:x:30003:30000:Guix build user 3:/var/empty:/bin/sh\n'
} > "$work/etc/passwd"
{
  printf 'root:x:0:\n'
  printf 'nogroup:x:65534:\n'
  printf 'guixbuild:x:30000:guixbuilder01,guixbuilder02,guixbuilder03\n'
} > "$work/etc/group"
printf 'passwd: files\ngroup: files\nshadow: files\nhosts: files dns\n' > "$work/etc/nsswitch.conf"

# --- fresh store database (schema 7) ---
sqlite3 "$work/var-guix/db/db.sqlite" < "$root/guix/store/schema.sql"
printf 7 > "$work/var-guix/db/schema"

# --- the guix client the daemon resolves via the configured bindir (/bin/guix) ---
# Bind-mount a scratch /bin holding guix + sh (the host /bin has sh but no guix).
# Only the worktree mode bind-mounts this /bin; the installed (CI-like) package
# resolves its own helpers.
#
# The entries must NOT point back into the directory the bind replaces.  On a
# merged-/usr host (Ubuntu, WSL) /bin is a SYMLINK to usr/bin, so binding over
# /bin lands on /usr/bin: an entry pointing at /usr/bin/bash then resolves to
# itself and exec fails with ELOOP ("Too many levels of symbolic links", exit
# 126).  `command -v bash` yields exactly that host path when the caller is not
# inside the dev shell.  Resolve to the real file instead: readlink -f gives a
# store path for a dev-shell tool, which stays reachable because /nix/store is
# bind-mounted into the namespace and is never the bind target.
#
# Refuse a target that still lives under the replaced directory rather than
# create a link that cannot resolve.
link_outside_bin() { # name resolved-target
  local name=$1 target=$2
  target=$(readlink -f "$target" 2>/dev/null || printf '%s' "$target")
  case "$target" in
    /bin/*|/usr/bin/*)
      echo "root-ci-setup: $name resolves to $target, inside the directory the scratch /bin replaces; run inside the dev shell so it resolves to a store path" >&2
      return 1;;
  esac
  ln -sf "$target" "$work/bin/$name"
}
cp "$root/scripts/guix" "$work/bin/guix"
chmod +x "$work/bin/guix"
link_outside_bin sh "$(command -v sh)" || exit 1
# bash too: the runner execs the PID-namespace part with bash AFTER this
# scratch /bin is bind-mounted over /bin, so a bare `bash` (or $BASH=/bin/bash
# on a merged-usr host) would be hidden.  Link the real one in.
link_outside_bin bash "$(command -v bash)" || exit 1

# --- a local git repo for builtin:git-download ---
git init -q "$work/gitrepo"
git -C "$work/gitrepo" config user.email t@t
git -C "$work/gitrepo" config user.name t
printf 'git-download payload\n' > "$work/gitrepo/file.txt"
git -C "$work/gitrepo" add file.txt
git -C "$work/gitrepo" commit -qm init
git -C "$work/gitrepo" rev-parse HEAD > "$work/gitrev"

# --- a payload file for builtin:download (served by socat HTTP inside the ns) ---
printf 'download payload\n' > "$work/payload.txt"

echo "work=$work"
echo "SETUP_OK"
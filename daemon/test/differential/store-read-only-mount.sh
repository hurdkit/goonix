#!/usr/bin/env bash
# Regression: a daemon whose store is a read-only mount, as Guix System and
# NixOS mount /gnu/store, starts, keeps running and writes to the store, while
# the store stays read-only for everybody else.
#
# The C++ LocalStore constructor creates the store directory and then calls
# ensureStoreWritable (nix/libstore/local-store.cc): on a read-only mount a
# root daemon unshares its mount namespace and remounts the store writable
# with MS_REMOUNT | MS_BIND, in the process of each connection, so that the
# builds it starts see the writable store too; a daemon that is not root fails
# with "'STORE' is read-only; make sure to mount it read-write for proper
# guix-daemon operation".  The Haskell daemon did neither: started by systemd
# on such a store, it changed the store's owner and failed with
# "setOwnerAndGroup: permission denied (Read-only file system)", and, socket
# activated, it then exited with status 0.  A fatal error at start-up must end
# the daemon with a non-zero status, as an error that reaches the C++ main
# does (EXIT_FAILURE).
#
# Each case starts the daemon socket-activated, as systemd does, as root of a
# user namespace whose build users are the caller's subordinate IDs:
#   chroot  read-only store, build users, chroot builds: a text is added and a
#           derivation built; the daemon is still running afterwards; outside
#           its namespace the store is still read-only.
#   direct  the same with --disable-chroot: the builder runs in the daemon's
#           own mount namespace and writes its output there.
#   group   a writable store and a build users group that does not exist: the
#           daemon either refuses the client with C++'s message or ends with
#           a non-zero status and that message; it never ends with status 0.
#   user    read-only store, the daemon not root (a nested user namespace):
#           it either refuses the client with C++'s message or ends with a
#           non-zero status and that message.
# Both daemons must pass it.  No sudo: util-linux unshare maps the caller to
# root of the namespace and the subordinate range of /etc/subuid and
# /etc/subgid beside it (newuidmap and newgidmap; on NixOS the setuid wrappers
# of /run/wrappers/bin).  The daemon runs in a PID namespace of its own, so
# that killing a build user's processes reaches no other job's builders.
#
# Usage: store-read-only-mount.sh [DAEMON] [WORK]
# DAEMON defaults to the daemon of this tree.  WORK (default
# /tmp/goonix-store-read-only-mount) is removed and created again; the build
# users must be able to reach it, so it must not be under a home directory
# that others cannot enter.  For a Haskell daemon outside the tree, set
# GUIX_SANDBOX to its sandbox helper.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
here=$root/daemon/test/differential
self=$here/store-read-only-mount.sh
client=$here/store-read-only-mount.scm

# The builds run the bootstrap bash of (guix tests), which keeps the file in
# the tree once it has downloaded it.  In the namespace the build users would
# run that download from a tree that they may not be able to enter, so when
# the tree has none it is downloaded here, through the daemon under test run
# as the caller on a store of its own, as unrelated-reference.sh has it done.
fetch_bootstrap() { # DAEMON DIRECTORY
  local daemon=$1 dir=$2
  if GUIX_DAEMON_SOCKET=$dir/no-daemon "$root/pre-inst-env" guile --no-auto-compile \
       "$client" bootstrap > /dev/null 2>&1; then
    return 0
  fi
  "$here/prepare-write-fixture.sh" "$dir" > /dev/null
  if ! (
    export NIX_STORE_DIR=$dir/store GUIX_DATABASE_DIRECTORY=$dir/db
    export GUIX_STATE_DIRECTORY=$dir/var GUIX_DAEMON_SOCKET=$dir/socket
    export GUIX_LOG_DIRECTORY=$dir/var/log/guix GUIX_CONFIGURATION_DIRECTORY=$dir/etc
    export XDG_CACHE_HOME=$dir/cache
    status=0
    goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --no-substitutes \
      --listen="$GUIX_DAEMON_SOCKET" > "$dir/daemon.log" 2>&1
    pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
    for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; sleep .01; done
    goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$client" bootstrap \
      > "$dir/client.log" 2>&1 || status=$?
    goonix_stop_capped "$pid" "$scope"
    exit "$status"
  ); then
    echo "cannot run: the bootstrap bash could not be downloaded; see $dir" >&2
    exit 2
  fi
}

# --- outside: check what the namespaces need, then enter them ---
outside() {
  . "$root/daemon/test/lib.sh"
  local daemon work user uid gid subuid subgid
  daemon=$(readlink -f "${1:-${GOONIX_TEST_DAEMON:-$root/guix-daemon}}")
  work=${2:-/tmp/goonix-store-read-only-mount}
  case "$work" in /*) ;; *) work=$PWD/$work ;; esac
  test -x "$daemon" || { echo "cannot run: no daemon at $daemon" >&2; exit 2; }
  test -x "$root/pre-inst-env" || { echo "cannot run: the tree is not built" >&2; exit 2; }
  user=$(id -un) uid=$(id -u) gid=$(id -g)
  # NAME:START:COUNT; the build users below need the inner IDs up to 30003.
  range() {
    awk -F: -v name="$user" -v id="$2" \
      '($1 == name || $1 == id) && $3 >= 30003 { print $2 ":" $3; exit }' "$1"
  }
  subuid=$(range /etc/subuid "$uid") subgid=$(range /etc/subgid "$uid")
  if test -z "$subuid" || test -z "$subgid"; then
    echo "cannot run: no subordinate ID range of at least 30003 for $user in /etc/subuid and /etc/subgid" >&2
    exit 2
  fi
  if test -d /run/wrappers/bin; then PATH=/run/wrappers/bin:$PATH; fi
  export PATH GUILE_AUTO_COMPILE=0
  GOONIX_TEST_TIMEOUT=${GOONIX_TEST_TIMEOUT:-600}
  export GOONIX_TEST_TIMEOUT
  mkdir -p "$work"
  fetch_bootstrap "$daemon" "$work/bootstrap"
  goonix_run_capped unshare --user \
    --map-users=0:"$uid":1 --map-users=1:"$subuid" \
    --map-groups=0:"$gid":1 --map-groups=1:"$subgid" \
    --mount -- bash "$self" --namespace "$daemon" "$work"
}

# --- root of the user namespace, in its own mount namespace ---
namespace() {
  local daemon=$1 work=$2 name
  if test -e "$work"; then chmod -R u+rwX "$work" 2>/dev/null || true; rm -rf "$work"; fi
  test ! -e "$work" || { echo "cannot run: $work cannot be removed" >&2; exit 2; }
  mkdir -p "$work/etc"
  # Build users in the subordinate range; NSS reads the files below, not nscd.
  {
    printf 'root:x:0:0:root:/root:/bin/sh\n'
    printf 'nobody:x:65534:65534:nobody:/var/empty:/bin/sh\n'
    printf 'guixbuilder01:x:30001:30000:Guix build user 1:/var/empty:/bin/sh\n'
    printf 'guixbuilder02:x:30002:30000:Guix build user 2:/var/empty:/bin/sh\n'
    printf 'guixbuilder03:x:30003:30000:Guix build user 3:/var/empty:/bin/sh\n'
    printf 'guix-daemon:x:1000:1000:the daemon that is not root:/var/empty:/bin/sh\n'
  } > "$work/etc/passwd"
  {
    printf 'root:x:0:\n'
    printf 'nogroup:x:65534:\n'
    printf 'guix-daemon:x:1000:\n'
    printf 'guixbuild:x:30000:guixbuilder01,guixbuilder02,guixbuilder03\n'
  } > "$work/etc/group"
  printf 'passwd: files\ngroup: files\nshadow: files\nhosts: files dns\n' > "$work/etc/nsswitch.conf"
  mount --bind "$work/etc/passwd" /etc/passwd
  mount --bind "$work/etc/group" /etc/group
  mount --bind "$work/etc/nsswitch.conf" /etc/nsswitch.conf
  mount --bind /dev/null /var/run/nscd/socket 2>/dev/null || true
  for name in chroot direct group user; do
    "$here/prepare-write-fixture.sh" "$work/$name" > /dev/null
    mkdir -p "$work/$name/etc" "$work/$name/tmp" "$work/$name/cache"
    cp "$root/tests/keys/openpgp/signing-key.sec" "$root/tests/keys/openpgp/signing-key.pub" \
      "$work/$name/etc/"
    chmod 0400 "$work/$name/etc/signing-key.sec"
  done
  # The build users run builders in the store and in TMPDIR.
  local dir=$work
  while test "$dir" != /; do
    case "$(stat -c %A "$dir")" in
      ?????????[xt]) ;;
      *) echo "cannot run: build users cannot enter $dir; give a WORK elsewhere" >&2; exit 2 ;;
    esac
    dir=$(dirname "$dir")
  done
  # The store as Guix System and NixOS mount it: a read-only bind mount.
  for name in chroot direct user; do
    mount --bind "$work/$name/store" "$work/$name/store"
    mount -o remount,bind,ro "$work/$name/store"
  done
  exec unshare --pid --fork --kill-child --mount-proc -- \
    bash "$self" --cases "$daemon" "$work" "$(readlink /proc/self/ns/pid)"
}

# --- PID 1 of a PID namespace of its own ---
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

# Whether PID is a process that has not ended (a zombie has).
running() {
  local state
  state=$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1) || return 1
  test -n "$state" && test "$state" != Z
}

# The per-mount options of the mount at MOUNT-POINT as process PID sees it.
mount_options() {
  awk -v point="$2" '$5 == point { options = $6 } END { print options }' "/proc/$1/mountinfo"
}

# Point the daemon and the client at case NAME's fixture.
use_fixture() {
  fixture=$work/$1
  export NIX_STORE_DIR=$fixture/store GUIX_DATABASE_DIRECTORY=$fixture/db
  export GUIX_STATE_DIRECTORY=$fixture/var GUIX_DAEMON_SOCKET=$fixture/socket
  export GUIX_LOG_DIRECTORY=$fixture/var/log/guix GUIX_CONFIGURATION_DIRECTORY=$fixture/etc
  export XDG_CACHE_HOME=$fixture/cache TMPDIR=$fixture/tmp
}

# Start the daemon socket-activated: start [PREFIX...] -- OPTION...
start() {
  local prefix=()
  while test "$1" != --; do prefix+=("$1"); shift; done
  shift
  "${prefix[@]}" "$root/pre-inst-env" guile --no-auto-compile "$client" \
    activate "$GUIX_DAEMON_SOCKET" "$daemon" --no-substitutes "$@" \
    > "$fixture/daemon.log" 2>&1 &
  dpid=$!
  # The socket is there once the activation has bound it, before the daemon
  # runs; a client that connects then waits for the daemon.
  local i
  for i in $(seq 1 3000); do
    test -S "$GUIX_DAEMON_SOCKET" && break
    running "$dpid" || break
    sleep .01
  done
}

# End the daemon and tell how it ended.
stop() {
  local status=0
  if running "$dpid"; then kill -TERM "$dpid" 2>/dev/null || true; fi
  wait "$dpid" || status=$?
  echo "daemon status: $status" >> "$fixture/daemon.log"
}

client_run() { # MODE ARG...
  timeout 180 "$root/pre-inst-env" guile --no-auto-compile "$client" "$@" \
    > "$fixture/client.log" 2>&1 || true
  sed 's/^/  client: /' "$fixture/client.log"
}

serve_case() { # NAME DAEMON-OPTION...
  local name=$1 store_view outside_view status
  shift
  use_fixture "$name"
  start -- --build-users-group=guixbuild "$@"
  client_run serve "$GUIX_DAEMON_SOCKET" "$name-$$-$(date +%s%N)"
  if ! grep -qx 'store-read-only-mount client: served' "$fixture/client.log"; then
    fail "$name: the daemon did not serve the client"
  fi
  if running "$dpid"; then
    store_view=$(mount_options "$dpid" "$NIX_STORE_DIR")
    echo "  the daemon's process sees the store mounted $store_view;" \
      "its mount namespace is $(readlink "/proc/$dpid/ns/mnt"), the test's $(readlink /proc/self/ns/mnt)"
  else
    status=0
    wait "$dpid" || status=$?
    fail "$name: the daemon ended with status $status"
    sed 's/^/  daemon: /' "$fixture/daemon.log"
    dpid=
  fi
  outside_view=$(mount_options self "$NIX_STORE_DIR")
  case ",$outside_view," in
    *,ro,*) ;;
    *) fail "$name: outside the daemon's namespace the store is mounted $outside_view" ;;
  esac
  if touch "$NIX_STORE_DIR/.outside" 2> "$fixture/touch.err"; then
    fail "$name: outside the daemon's namespace the store is writable"
  elif ! grep -q 'Read-only file system' "$fixture/touch.err"; then
    fail "$name: writing the store outside the daemon's namespace: $(cat "$fixture/touch.err")"
  fi
  if test -n "$dpid"; then stop; fi
  echo "case $name: done"
}

# The daemon must refuse the client with MESSAGE or end with a non-zero status
# after printing MESSAGE.
refusal_case() { # NAME MESSAGE START-ARGUMENT...
  local name=$1 message=$2 status
  shift 2
  use_fixture "$name"
  start "$@"
  client_run refused "$GUIX_DAEMON_SOCKET"
  if running "$dpid"; then
    if ! grep -q '^refused: ' "$fixture/client.log"; then
      fail "$name: the daemon is running and did not refuse the client"
    elif ! grep -Fq "$message" "$fixture/client.log"; then
      fail "$name: the daemon refused the client without saying \"$message\""
    fi
    stop
  else
    status=0
    wait "$dpid" || status=$?
    echo "  the daemon ended with status $status"
    sed 's/^/  daemon: /' "$fixture/daemon.log"
    if test "$status" -eq 0; then
      fail "$name: the daemon ended with status 0"
    fi
    if ! grep -Fq "$message" "$fixture/daemon.log"; then
      fail "$name: the daemon ended without saying \"$message\""
    fi
  fi
  echo "case $name: done"
}

run_cases() {
  daemon=$1 work=$2
  # As pidns-guard.sh checks, but against the namespace that this one was
  # entered from: /proc is this namespace's own (--mount-proc), so that the
  # daemon's PID names it there.
  if test "$$" != 1 || test "$(readlink /proc/self/ns/pid)" = "$3"; then
    echo "cannot run: not PID 1 of a PID namespace of its own" >&2
    exit 3
  fi
  echo "daemon: $daemon"
  serve_case chroot
  serve_case direct --disable-chroot
  refusal_case group \
    "the group \`goonix-no-such-group' specified in \`build-users-group' does not exist" \
    -- --build-users-group=goonix-no-such-group --disable-chroot
  refusal_case user \
    "'$work/user/store' is read-only; make sure to mount it read-write for proper guix-daemon operation" \
    unshare --user --map-user=1000 --map-group=1000 -- --disable-chroot
  if test "$failures" -eq 0; then
    echo "store-read-only-mount: PASS"
  else
    echo "store-read-only-mount: FAIL ($failures)"
    exit 1
  fi
}

case "${1:-}" in
  --namespace) shift; namespace "$@" ;;
  --cases) shift; run_cases "$@" ;;
  *) outside "$@" ;;
esac

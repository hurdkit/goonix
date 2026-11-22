#!/usr/bin/env bash
# goonix: Unix-socket start-up parity (HS-8 switch-2 CI fix).  The C++ daemon's
# open_unix_domain_socket creates the socket directory, chdir-binds the relative
# name (so a >108-byte absolute path still listens), unlinks a stale socket, and
# binds 0666 under umask(0111).  Each case runs BOTH daemons on a fresh root and
# requires a client to connect.  Calibrated: the empty-root, long-path and
# umask cases FAIL on the pre-fix Haskell daemon (8c60954) and PASS on the fix.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
out=${1:-$root/.scratch/socket-startup}
cxx=${GOONIX_CXX_DAEMON:-$root/.scratch/hs0-cxx-daemon}
hs=${GOONIX_HS_DAEMON:-$root/guix-daemon}
for daemon in "$cxx" "$hs"; do test -x "$daemon"; done
if test -e "$out"; then chmod -R u+rwX "$out" 2>/dev/null || true; rm -rf "$out"; fi
mkdir -p "$out"
export GUILE_AUTO_COMPILE=0
cc -O2 -Wall -Wextra "$root/daemon/test/differential/stale-socket.c" -o "$out/stale-socket"
cc -O2 -Wall -Wextra "$root/daemon/test/differential/socket-connect.c" -o "$out/socket-connect"

# A long directory component so the absolute socket path exceeds sun_path's 108
# bytes while the relative "./socket" stays short.
long=$(printf 'l%.0s' $(seq 1 120))

start_and_connect() {
  # name daemon socket-path [prepare] [client]
  local name=$1 daemon=$2 socket=$3 prepare=${4:-} client=${5:-guile}
  local fixture=$out/$name
  mkdir -p "$fixture"
  # Fresh store + database; the STATE root is left nonexistent on purpose.
  "$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture/base" >/dev/null
  export NIX_STORE_DIR="$fixture/base/store"
  export GUIX_DATABASE_DIRECTORY="$fixture/base/db"
  export GUIX_STATE_DIRECTORY="$fixture/var"
  export GUIX_DAEMON_SOCKET="$socket"
  export GUIX_LOG_DIRECTORY="$fixture/var/log/guix"
  export GUIX_CONFIGURATION_DIRECTORY="$fixture/etc"
  case "$prepare" in
    stale)
      mkdir -p "$(dirname "$socket")"
      # A stale socket file left by a killed daemon.
      "$out/stale-socket" "$socket"
      ;;
    umask)
      umask 077
      ;;
  esac
  goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --listen="$socket" >"$fixture/daemon.log" 2>&1
  local pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
  local i
  for i in $(seq 1 300); do test -S "$socket" && break; kill -0 "$pid" 2>/dev/null || break; sleep .01; done
  if ! test -S "$socket"; then
    echo "FAIL: $name: daemon did not open its socket" >&2
    cat "$fixture/daemon.log" >&2 || true
    goonix_stop_capped "$pid" "$scope"
    return 1
  fi
  # A client connects and queries the store.  For a >108-byte path the Guile
  # client cannot connect (scm_to_sockaddr rejects it), so verify the daemon is
  # listening with the relative-name C connector instead.
  if test "$client" = c; then
    if ! "$out/socket-connect" "$socket" >"$fixture/client.out" 2>"$fixture/client.err"; then
      echo "FAIL: $name: client could not connect" >&2
      cat "$fixture/client.err" >&2 || true
      goonix_stop_capped "$pid" "$scope"
      return 1
    fi
  elif ! goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile -c \
      '(use-modules (guix store)) (let ((s (open-connection (getenv "GUIX_DAEMON_SOCKET")))) (display (length (live-paths s))) (newline))' \
      >"$fixture/client.out" 2>"$fixture/client.err"; then
    echo "FAIL: $name: client could not connect/query" >&2
    cat "$fixture/client.err" >&2 || true
    goonix_stop_capped "$pid" "$scope"
    return 1
  fi
  if test "$prepare" = umask; then
    local mode
    mode=$(stat -c '%a' "$socket")
    if test "$mode" != 666; then
      echo "FAIL: $name: socket mode is $mode, want 666" >&2
      goonix_stop_capped "$pid" "$scope"
      return 1
    fi
    umask 022
  fi
  goonix_stop_capped "$pid" "$scope"
  echo "PASS: $name"
}

status=0
# Two --listen paths in different directories: both sockets must appear (0666)
# and accept a client.  Binding mutates the process-wide umask and cwd, so the
# daemon must open every listener sequentially before forking accept loops;
# otherwise the two binds race (one binds ./socket in the other's directory).
start_two_listeners() {
  local name=$1 daemon=$2
  local fixture=$out/$name
  mkdir -p "$fixture"
  "$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture/base" >/dev/null
  export NIX_STORE_DIR="$fixture/base/store"
  export GUIX_DATABASE_DIRECTORY="$fixture/base/db"
  export GUIX_STATE_DIRECTORY="$fixture/var"
  export GUIX_LOG_DIRECTORY="$fixture/var/log/guix"
  export GUIX_CONFIGURATION_DIRECTORY="$fixture/etc"
  local s1="$fixture/var/daemon-socket/socket"
  local s2="$fixture/var/other-socket/socket"
  export GUIX_DAEMON_SOCKET="$s1"
  goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --listen="$s1" --listen="$s2" >"$fixture/daemon.log" 2>&1
  local pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
  local i
  for i in $(seq 1 300); do test -S "$s1" && test -S "$s2" && break; kill -0 "$pid" 2>/dev/null || break; sleep .01; done
  if ! test -S "$s1" || ! test -S "$s2"; then
    echo "FAIL: $name: both sockets did not appear (s1=$(test -S "$s1" && echo yes || echo no) s2=$(test -S "$s2" && echo yes || echo no))" >&2
    cat "$fixture/daemon.log" >&2 || true
    goonix_stop_capped "$pid" "$scope"
    return 1
  fi
  local m1 m2
  m1=$(stat -c '%a' "$s1"); m2=$(stat -c '%a' "$s2")
  if test "$m1" != 666 || test "$m2" != 666; then
    echo "FAIL: $name: socket modes $m1/$m2, want 666/666" >&2
    goonix_stop_capped "$pid" "$scope"
    return 1
  fi
  if ! "$out/socket-connect" "$s1" >"$fixture/c1.out" 2>"$fixture/c1.err" \
     || ! "$out/socket-connect" "$s2" >"$fixture/c2.out" 2>"$fixture/c2.err"; then
    echo "FAIL: $name: a client could not connect to both sockets" >&2
    cat "$fixture/c1.err" "$fixture/c2.err" >&2 || true
    goonix_stop_capped "$pid" "$scope"
    return 1
  fi
  goonix_stop_capped "$pid" "$scope"
  echo "PASS: $name"
}

for pair in "cxx:$cxx" "hs:$hs"; do
  name=${pair%%:*}; daemon=${pair#*:}
  start_and_connect "$name-empty" "$daemon" "$out/$name-empty/var/daemon-socket/socket" || status=1
  start_and_connect "$name-long" "$daemon" "$out/$name-long/$long/var/daemon-socket/socket" "" c || status=1
  start_and_connect "$name-stale" "$daemon" "$out/$name-stale/var/daemon-socket/socket" stale || status=1
  start_and_connect "$name-umask" "$daemon" "$out/$name-umask/var/daemon-socket/socket" umask || status=1
  start_two_listeners "$name-two" "$daemon" || status=1
done
if test "$status" -eq 0; then
  printf 'socket start-up differential: PASS\n'
else
  printf 'socket start-up differential: FAIL\n' >&2
fi
exit "$status"
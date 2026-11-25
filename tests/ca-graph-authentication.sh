#!/usr/bin/env bash
# goonix: a graph record with an altered path is refused despite its signature.
set -euo pipefail
root=$(mktemp -d "${TMPDIR:-/tmp}/goonix-graph-auth-XXXXXX")
store=${root}-store
server=$root/server client=$root/client
port=${GOONIX_TAMPER_PORT:-6891}
server_pid= cache_pid= client_pid=
completed=false
cleanup() {
  for pid in $client_pid $cache_pid $server_pid; do
    if test -n "$pid"; then kill "$pid" 2>/dev/null || true; fi
  done
  wait 2>/dev/null || true
  if $completed; then
    chmod -R u+w "$root" "$store" 2>/dev/null || true
    rm -rf "$root" "$store"
  else
    printf 'retained graph-authentication fixture: %s\n' "$root" >&2
  fi
}
trap cleanup EXIT INT TERM
mkdir -p "$store" "$server/db" "$server/etc" "$server/state" "$server/log" \
         "$client/db" "$client/etc" "$client/state" "$client/log"
chmod 700 "$server/etc" "$client/etc"
for side in "$server/etc" "$client/etc"; do
  cp tests/keys/openpgp/signing-key.sec tests/keys/openpgp/signing-key.pub "$side/"
  chmod 400 "$side/signing-key.sec"
done
{
  printf '(acl (entry '
  cat tests/keys/openpgp/signing-key.pub
  printf ' (tag (guix import))))\n'
} > "$client/etc/acl"
printf '#!/bin/sh\nexec /bin/sh "$@"\n' > "$root/shell"
chmod 755 "$root/shell"
export NIX_STORE_DIR=$store GUIX_CONFIGURATION_DIRECTORY=$server/etc
export GUIX_DATABASE_DIRECTORY=$server/db GUIX_STATE_DIRECTORY=$server/state
export GUIX_DAEMON_SOCKET=$server/socket GUIX_LOG_DIRECTORY=$server/log
export GOONIX_SHELL_SOURCE=$root/shell GOONIX_TAMPER_ROOT=$root
export GOONIX_CACHE_URL=http://127.0.0.1:$port
./guix-daemon --disable-chroot --no-substitutes --listen="$server/socket" \
  >"$root/server-daemon.log" 2>&1 & server_pid=$!
for i in $(seq 1 100); do test -S "$server/socket" && break; sleep .1; done
./pre-inst-env guile --no-auto-compile tests/ca-tampered-fixture.scm server \
  >"$root/server-client.log" 2>&1
GUIX_DATABASE_DIRECTORY=$server/db GUIX_CONFIGURATION_DIRECTORY=$server/etc \
GUIX_STATE_DIRECTORY=$server/state GUIX_DAEMON_SOCKET=$server/socket \
GOONIX_TAMPER_PORT=$port ./pre-inst-env guile --no-auto-compile \
  tests/ca-tampered-cache.scm >"$root/cache.log" 2>&1 & cache_pid=$!
for i in $(seq 1 100); do
  if timeout 1 bash -c "</dev/tcp/127.0.0.1/$port" 2>/dev/null; then break; fi
  sleep .1
done
kill "$server_pid"; wait "$server_pid" 2>/dev/null || true
server_pid=
export GUIX_CONFIGURATION_DIRECTORY=$client/etc GUIX_DATABASE_DIRECTORY=$client/db
export GUIX_STATE_DIRECTORY=$client/state GUIX_DAEMON_SOCKET=$client/socket
export GUIX_LOG_DIRECTORY=$client/log GOONIX_TAMPER_URL=http://127.0.0.1:$port
./guix-daemon --disable-chroot --listen="$client/socket" \
  --substitute-urls="$GOONIX_TAMPER_URL" >"$root/client-daemon.log" 2>&1 & client_pid=$!
for i in $(seq 1 100); do test -S "$client/socket" && break; sleep .1; done
./pre-inst-env guile --no-auto-compile tests/ca-tampered-fixture.scm client \
  >"$root/client.log" 2>&1
# The fixture checks the forged path is absent and only a local record remains.
grep -F 'GET /goonix/records/' "$root/cache.log"
completed=true
printf 'graph tampered-record refusal: PASS\n'

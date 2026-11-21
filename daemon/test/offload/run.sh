#!/usr/bin/env bash
# goonix: integration probe for the real daemon/helper boundary.
# This is deliberately a probe, not the HS-5 Guix test-suite gate.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
out="$root/.scratch/hs5-offload-fixture"
daemon=${GOONIX_TEST_DAEMON:-$root/guix-daemon}
helper_program=${GOONIX_OFFLOAD_PROGRAM:-$root/daemon/test/offload/helper.sh}
if test -e "$out"; then chmod -R u+rwX "$out"; rm -rf "$out"; fi
mkdir -p "$out"
if test "$#" -gt 1; then
  shift
  exec goonix_run_capped "$@"
fi
export GOONIX_OFFLOAD_PROGRAM="$helper_program"
export GOONIX_DAEMON_OPTIONS="--disable-chroot --no-substitutes"
export GUIX_LOG_COMPRESSION=none
if test "${GOONIX_REAL_OFFLOAD:-0}" = 1; then
  export GOONIX_OFFLOAD_PROGRAM="$root/scripts/guix"
fi

run_case() {
  name=$1; reply=$2; result=$3; status=$4; replies=${5:-}
  fixture=$out/$name
  "$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
  export HS5_ROOT="$fixture"
  export HS5_REPLY="$reply" HS5_RESULT="$result"
  if test -n "$replies"; then export HS5_REPLIES="$replies"; else unset HS5_REPLIES; fi
  if test "$name" = accept; then
    export HS5_BUILDER_OUTPUT=yes HS5_DIAGNOSTIC=yes
  else
    unset HS5_BUILDER_OUTPUT HS5_DIAGNOSTIC
  fi
  export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
  export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
  export GUIX_LOG_DIRECTORY="$fixture/var/log/guix" GUIX_CONFIGURATION_DIRECTORY="$fixture/etc"
  mkdir -p "$GUIX_CONFIGURATION_DIRECTORY"
  cp "$root/tests/keys/openpgp/signing-key.sec" "$GUIX_CONFIGURATION_DIRECTORY/signing-key.sec"
  cp "$root/tests/keys/openpgp/signing-key.pub" "$GUIX_CONFIGURATION_DIRECTORY/signing-key.pub"
  chmod 0400 "$GUIX_CONFIGURATION_DIRECTORY/signing-key.sec"
  # The daemon is intentionally started on a fresh, private store.
  goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --no-substitutes \
    --disable-log-compression \
    --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1
  pid=$GOONIX_TEST_PID
  daemon_scope=$GOONIX_TEST_SCOPE
  trap 'goonix_stop_capped "$pid" "$daemon_scope"' EXIT
  for i in $(seq 1 300); do
    test -S "$GUIX_DAEMON_SOCKET" && break
    kill -0 "$pid"
    sleep .01
  done
  test -S "$GUIX_DAEMON_SOCKET"
  goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile \
    "$root/daemon/test/offload/client.scm" "$name" "$status" \
    >"$fixture/client.log" 2>&1
  goonix_stop_capped "$pid" "$daemon_scope"
  wait "$pid" 2>/dev/null || true
  trap - EXIT
  cat "$fixture/client.log"
}

if test "${GOONIX_REAL_OFFLOAD:-0}" = 1; then
  run_case decline unused unused 0
else
  run_case accept accept success 0
  run_case accept-twice accept success 0
  run_case decline decline unused 0
  run_case no-offload decline unused 0
  run_case postpone postpone success 0 'postpone accept'
  run_case fail17 accept exit17 1
  run_case fail100 accept exit100 100
  run_case unregistered accept unregistered 1
fi

if test "${GOONIX_REAL_OFFLOAD:-0}" = 1; then
  test -e "$out/decline/local-builds"
  printf 'real guix offload decline and local build: PASS\n'
  exit 0
fi
# No local builder may have run in accepted cases, including failures.
for name in accept accept-twice postpone fail17 fail100 unregistered; do
  test ! -e "$out/$name/local-builds"
done
# An accepted helper exits after the build and cannot be reused by the next
# derivation on the same connection.
test "$(grep -c '^args ' "$out/accept-twice/helper.log")" = 2
test "$(grep -c '^registered ' "$out/accept-twice/helper.log")" = 2
# A decline is the one case where a local builder is required.
test -e "$out/decline/local-builds"
# An explicit client opt-out must build locally without starting a helper.
test -e "$out/no-offload/local-builds"
test ! -e "$out/no-offload/helper.log"
# The two offers belong to one reused helper, and the build was not local.
test "$(grep -c '^args ' "$out/postpone/helper.log")" = 1
test "$(grep -c '^request ' "$out/postpone/helper.log")" = 2
grep -q '^registered ' "$out/accept/helper.log"
# Both output streams and the accepted-output registration are exercised.
grep -q 'offloaded builder output' "$out/accept/client.log"
grep -q 'helper diagnostic' "$out/accept/client.log"
grep -q 'offloaded builder output' "$out/accept/var/log/guix/drvs"/*/*
printf 'offload daemon integration probe: PASS\n'

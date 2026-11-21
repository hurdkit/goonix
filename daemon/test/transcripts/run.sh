#!/usr/bin/env bash
# Compare logical helper streams; the recording helper is a probe, not the HS-5 gate.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
out=${1:-$root/.scratch/hs5-transcript-fixture}
cxx=${GOONIX_CXX_DAEMON:-$root/.scratch/hs0-cxx-daemon}
hs=${GOONIX_HS_DAEMON:-$root/guix-daemon}
for daemon in "$cxx" "$hs"; do test -x "$daemon"; done
if test -e "$out"; then chmod -R u+rwX "$out" 2>/dev/null || true; rm -rf "$out"; fi
mkdir -p "$out"
cc -O2 -Wall -Wextra -Werror "$root/daemon/test/transcripts/record-helper.c" -o "$out/record-helper"
export GOONIX_ROOT="$root"
export GOONIX_TRANSCRIPT_RECORDER="$out/record-helper"

run_daemon() {
  local name=$1 daemon=$2
  fixture=$out/shared
  export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
  export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
  export GUIX_LOG_DIRECTORY="$fixture/var/log/guix" GUIX_CONFIGURATION_DIRECTORY="$fixture/etc"
  export GUIX_BINARY_SUBSTITUTE_URL="file://$fixture/substituter-data"
  export HS5_ROOT="$fixture" HS5_DERIVATION_COPY="$fixture/$name.drv"
  export GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES=yes
  export GOONIX_OFFLOAD_PROGRAM="$out/record-helper"
  goonix_start_capped "$root/daemon/test/transcripts/daemon-env.sh" "$daemon" --disable-chroot --allow-aslr \
    --substitute-urls="$GUIX_BINARY_SUBSTITUTE_URL" \
    --listen="$GUIX_DAEMON_SOCKET" >"$out/$name.daemon.log" 2>&1
  pid=$GOONIX_TEST_PID daemon_scope=$GOONIX_TEST_SCOPE
  trap 'goonix_stop_capped "$pid" "$daemon_scope"' EXIT
  for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
  test -S "$GUIX_DAEMON_SOCKET"
}

query_case() {
  local name=$1 query=$2 daemon=$3
  export GOONIX_HELPER_TRANSCRIPT="$out/$name.$query.txt"
  run_daemon "$name.$query" "$daemon"
  goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile \
    "$out/transcript-query.scm" "$query" >"$out/$name.$query.client.log" 2>&1 || true
  test -s "$out/$name.$query.txt"
  goonix_stop_capped "$pid" "$daemon_scope"
  trap - EXIT
}

run_capture() {
  local name=$1 daemon=$2
  chmod -R u+rwX "$out/shared" 2>/dev/null || true
  rm -rf "$out/shared"
  "$root/daemon/test/differential/prepare-write-fixture.sh" "$out/shared"
  mkdir -p "$out/shared/etc" "$out/shared/substituter-data" "$out/shared/cache"
  cp "$root/tests/keys/openpgp/signing-key.sec" "$out/shared/etc/signing-key.sec"
  cp "$root/tests/keys/openpgp/signing-key.pub" "$out/shared/etc/signing-key.pub"
  chmod 0400 "$out/shared/etc/signing-key.sec"
  query_case "$name" have "$daemon"
  query_case "$name" info "$daemon"
  query_case "$name" substitute "$daemon"
  export GOONIX_HELPER_TRANSCRIPT="$out/$name.offload.txt"
  run_daemon "$name.offload" "$daemon"
  goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile \
    "$out/transcript-client.scm" >"$out/$name.offload.client.log" 2>&1 || true
  goonix_stop_capped "$pid" "$daemon_scope"
  trap - EXIT
}

cp "$root/daemon/test/transcripts/transcript-query.scm" "$out/transcript-query.scm"
cp "$root/daemon/test/transcripts/transcript-client.scm" "$out/transcript-client.scm"
run_capture cxx "$cxx"
run_capture hs "$hs"
for case in have info substitute offload; do
  for implementation in cxx hs; do
    test -s "$out/$implementation.$case.txt"
    grep -Eq '^(stdin|stdout|fd4) [1-9][0-9]* ' "$out/$implementation.$case.txt" || {
      printf 'no captured protocol stream: %s\n' "$out/$implementation.$case.txt" >&2
      exit 1
    }
  done
  goonix_run_capped tclsh "$root/daemon/test/transcripts/normalize.tcl" \
    "$out/cxx.$case.txt" "$out/hs.$case.txt"
done
printf 'helper transcript probe: PASS\n'

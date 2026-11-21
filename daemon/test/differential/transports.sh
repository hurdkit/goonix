#!/usr/bin/env bash
# goonix: TCP and systemd-style socket activation checks, unprivileged only.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
fixture=${1:-/tmp/goonix-hs2-fixture/a}
out=${2:-$root/hs2-transports}
mkdir -p "$out"
if test ! -f "$fixture/query-path"; then
  mkdir -p "$(dirname "$fixture")"
  "$root/daemon/test/differential/prepare-readonly-fixture.sh" "$fixture" "$fixture"
fi
daemon=${HS_DAEMON:-$root/daemon/dist-newstyle/build/x86_64-linux/ghc-9.10.3/guix-daemon-hs-0.1.0.0/x/guix-daemon/build/guix-daemon/guix-daemon}
activation=${ACTIVATION_PROBE:-$root/daemon/dist-newstyle/build/x86_64-linux/ghc-9.10.3/guix-daemon-hs-0.1.0.0/x/goonix-activation-probe/build/goonix-activation-probe/goonix-activation-probe}
export NIX_STORE_DIR="$fixture/store"
export GUIX_DATABASE_PATH="$fixture/db/db.sqlite"
export GUIX_STATE_DIRECTORY="$fixture/var"
export GUIX_DAEMON_SOCKET=guix://localhost:45678
"$daemon" --disable-chroot --listen=localhost:45678 \
  --substitute-urls=file:///tmp/goonix-substitute > "$out/tcp.log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
sleep .2
"$root/pre-inst-env" guix gc --references $(cat "$fixture/query-path") > "$out/tcp.out"
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
trap - EXIT
export GUIX_DAEMON_SOCKET="$fixture/var/activated-test-socket"
"$activation" "$GUIX_DAEMON_SOCKET" "$daemon" "$NIX_STORE_DIR" "$GUIX_DATABASE_PATH" > "$out/activation.log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
for i in $(seq 1 200); do
  test -S "$GUIX_DAEMON_SOCKET" && break
  kill -0 "$pid"
  sleep .01
done
test -S "$GUIX_DAEMON_SOCKET"
kill -0 "$pid"
"$root/pre-inst-env" guix gc --references $(cat "$fixture/query-path") > "$out/activation.out"
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
trap - EXIT
printf 'TCP: PASS\nsocket activation: PASS\n'

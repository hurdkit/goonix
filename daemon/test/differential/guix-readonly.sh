#!/usr/bin/env bash
set -eu
cd /home/wrath/goonix/.worktrees/goonix-daemon-hs
root=$PWD
fixture=/tmp/goonix-hs2-guix
out=$root/hs2-guix
rm -rf "$fixture" "$out"
mkdir -p "$out"
"$root/daemon/test/differential/prepare-readonly-fixture.sh" "$fixture" "$fixture"
export NIX_STORE_DIR="$fixture/store"
export GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var"
export GUIX_DAEMON_SOCKET="$fixture/var/socket"
daemon=$root/daemon/dist-newstyle/build/x86_64-linux/ghc-9.10.3/guix-daemon-hs-0.1.0.0/x/guix-daemon/build/guix-daemon/guix-daemon
"$daemon" --disable-chroot --listen="$GUIX_DAEMON_SOCKET" >"$out/daemon.log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT INT TERM
for i in $(seq 1 200); do
  test -S "$GUIX_DAEMON_SOCKET" && break
  kill -0 "$pid"
  sleep .01
done
test -S "$GUIX_DAEMON_SOCKET"
kill -0 "$pid"
query_path=$(cat "$fixture/query-path")
"$root/pre-inst-env" guix gc --references "$query_path" >"$out/references.out"
"$root/pre-inst-env" guix gc --requisites "$query_path" >"$out/requisites.out"
"$root/pre-inst-env" guix size "$query_path" >"$out/size.out"
"$root/pre-inst-env" guix gc --list-roots >"$out/roots.out"
printf 'guix read-only queries: PASS\n'

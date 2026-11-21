#!/usr/bin/env bash
# goonix: differential read-only daemon checks on independent worktree stores.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
hs_daemon=${HS_DAEMON:-$root/daemon/dist-newstyle/build/x86_64-linux/ghc-9.10.3/guix-daemon-hs-0.1.0.0/x/guix-daemon/build/guix-daemon/guix-daemon}
cxx_daemon=${CXX_DAEMON:-$root/guix-daemon}
raw_client=${RAW_CLIENT:-$root/daemon/dist-newstyle/build/x86_64-linux/ghc-9.10.3/guix-daemon-hs-0.1.0.0/x/goonix-readonly-probe/build/goonix-readonly-probe/goonix-readonly-probe}
source_fixture=${1:-$root/hs2-live}
out=${2:-/tmp/goonix-hs2-differential}
mkdir -p "$out"
DAEMON_PID=
cleanup_daemon() {
  if test -n "$DAEMON_PID"; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
    DAEMON_PID=
  fi
}
trap cleanup_daemon EXIT INT TERM
prepare_fixture() {
  target=$1
  if test -e "$target"; then
    chmod -R u+w "$target" 2>/dev/null || true
    rm -rf "$target"
  fi
  "$root/daemon/test/differential/prepare-readonly-fixture.sh" "$target" "$target"
}
run_daemon() {
  name=$1
  daemon=$2
  fixture=$3
  export NIX_STORE_DIR="$fixture/store"
  export GUIX_STATE_DIRECTORY="$fixture/var"
  export GUIX_DATABASE_PATH="$fixture/db/db.sqlite"
  export GUIX_DATABASE_DIRECTORY="$fixture/db"
  export GUIX_DAEMON_SOCKET="$fixture/var/socket"
  "$daemon" --disable-chroot --allow-aslr \
    --listen="$GUIX_DAEMON_SOCKET" --substitute-urls="file:///tmp/goonix-substitute" \
    > "$out/$name.daemon.log" 2>&1 &
  DAEMON_PID=$!
  export DAEMON_PID
  i=0
  while test ! -S "$GUIX_DAEMON_SOCKET" && test "$i" -lt 200; do
    kill -0 "$DAEMON_PID"
    sleep .01
    i=$((i + 1))
  done
  test -S "$GUIX_DAEMON_SOCKET"
}
stop_daemon() {
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
}
prepare_fixture "$out/a"
prepare_fixture "$out/b"
run_daemon cxx "$cxx_daemon" "$out/a"
"$raw_client" "$GUIX_DAEMON_SOCKET" "$NIX_STORE_DIR" "$GUIX_STATE_DIRECTORY" > "$out/cxx.raw"
for command in roots references requisites size; do
  case $command in
    roots) args=(guix gc --list-roots) ;;
    references) args=(guix gc --references $(cat "$fixture/query-path")) ;;
    requisites) args=(guix gc --requisites $(cat "$fixture/query-path")) ;;
    size) args=(guix size $(cat "$fixture/query-path")) ;;
  esac
  "$root/pre-inst-env" "${args[@]}" > "$out/cxx-$command.out"
done
stop_daemon
run_daemon hs "$hs_daemon" "$out/b"
"$raw_client" "$GUIX_DAEMON_SOCKET" "$NIX_STORE_DIR" "$GUIX_STATE_DIRECTORY" > "$out/hs.raw"
for command in roots references requisites size; do
  case $command in
    roots) args=(guix gc --list-roots) ;;
    references) args=(guix gc --references $(cat "$fixture/query-path")) ;;
    requisites) args=(guix gc --requisites $(cat "$fixture/query-path")) ;;
    size) args=(guix size $(cat "$fixture/query-path")) ;;
  esac
  "$root/pre-inst-env" "${args[@]}" > "$out/hs-$command.out"
done
stop_daemon
# Store prefixes differ by design; normalize only that known prefix.
for command in roots references requisites size; do
  sed -e "s#$out/a/store#STORE#g" -e "s#$out/a/var#STATE#g" "$out/cxx-$command.out" > "$out/cxx-$command.norm"
  sed -e "s#$out/b/store#STORE#g" -e "s#$out/b/var#STATE#g" "$out/hs-$command.out" > "$out/hs-$command.norm"
  cmp "$out/cxx-$command.norm" "$out/hs-$command.norm"
  printf 'guix %s differential: PASS\n' "$command"
done
sed -e "s#$out/a/store#STORE#g" -e "s#$out/a/var#STATE#g" "$out/cxx.raw" > "$out/cxx.raw.norm"
sed -e "s#$out/b/store#STORE#g" -e "s#$out/b/var#STATE#g" "$out/hs.raw" > "$out/hs.raw.norm"
cmp "$out/cxx.raw.norm" "$out/hs.raw.norm"
printf 'read-only raw differential: PASS\n'

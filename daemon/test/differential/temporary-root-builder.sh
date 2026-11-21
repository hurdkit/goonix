#!/usr/bin/env bash
# One Haskell daemon, a marker-blocked builder, and a collector client.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${1:?Haskell daemon required}
out=${2:-$root/.scratch/hs7-temporary-roots-builder}
mkdir -p "$out"
find "$out" -mindepth 1 -maxdepth 1 -exec chmod -R u+rwX {} + 2>/dev/null || true
find "$out" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
out=$(CDPATH= cd -- "$out" && pwd)
fixture=$(mktemp -d /tmp/goonix-builder-gc-XXXXXX)
socket=$fixture/s
daemon_pid= daemon_scope= builder_pid= builder_scope= collector_pid= collector_scope=
cleanup() {
  status=$?
  trap - EXIT
  test -e "$fixture/release-builder" && : || touch "$fixture/release-builder"
  if test -n "$collector_pid"; then goonix_stop_capped "$collector_pid" "$collector_scope" || status=$?; fi
  if test -n "$builder_pid"; then goonix_stop_capped "$builder_pid" "$builder_scope" || status=$?; fi
  if test -n "$daemon_pid"; then goonix_stop_capped "$daemon_pid" "$daemon_scope" || status=$?; fi
  exec 9>&- || status=$?
  if test "$status" -ne 0; then
    cp -a "$fixture" "$out/fixture"
  fi
  rm -rf "$fixture"
  if test "$status" -eq 0; then
    chmod -R u+rwX "$out" 2>/dev/null || true
    rm -rf "$out"
  fi
  return "$status"
}
trap cleanup EXIT
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUILE_AUTO_COMPILE=0
export HS7_FIXTURE="$fixture" HS7_PHASE=hold
export HS7_HOLDER_SOCKET="$socket" HS7_COLLECTOR_SOCKET="$socket"
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix"
unset GUIX
mkdir -p "$NIX_STORE_DIR" "$GUIX_DATABASE_DIRECTORY" "$GUIX_STATE_DIRECTORY"
mkfifo "$fixture/tick"
exec 9<>"$fixture/tick"
goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --no-substitutes --listen="$socket" >"$out/daemon.log" 2>&1
daemon_pid=$GOONIX_TEST_PID daemon_scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 500); do test -S "$socket" && break; kill -0 "$daemon_pid"; sleep .01; done
test -S "$socket"
kill -0 "$daemon_pid"
goonix_start_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/differential/temporary-root-builder.scm" >"$out/builder.log" 2>&1
builder_pid=$GOONIX_TEST_PID builder_scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 1500); do
  test -s "$fixture/builder-started" && break
  if ! kill -0 "$builder_pid" 2>/dev/null; then
    wait "$builder_pid" || true
    cat "$out/builder.log"
    exit 1
  fi
  sleep .01
done
test -s "$fixture/builder-started" || { cat "$out/builder.log"; echo 'builder never started' >&2; exit 1; }
HS7_PHASE=seed goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile -c '(use-modules (guix store) (ice-9 rdelim)) (let* ((s (open-connection (getenv "HS7_COLLECTOR_SOCKET"))) (p (add-text-to-store s "hs7-dead-during-build" "dead")) (f (string-append (getenv "HS7_FIXTURE") "/dead-path"))) (close-connection s) (call-with-output-file f (lambda (port) (display p port) (newline port))))'
goonix_start_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/differential/temporary-root-builder-collect.scm" >"$out/collector.log" 2>&1
collector_pid=$GOONIX_TEST_PID collector_scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 1500); do
  test -e "$fixture/collector-finished" && break
  kill -0 "$collector_pid" || { wait "$collector_pid" || true; cat "$out/collector.log"; exit 1; }
  sleep .01
done
test -e "$fixture/collector-finished"
test ! -e "$fixture/builder-finished"
wait "$collector_pid"
collector_pid= collector_scope=
touch "$fixture/release-builder"
wait "$builder_pid"
builder_pid= builder_scope=
test -e "$fixture/build-client-finished"
test -e "$fixture/builder-finished"
test -f "$(cat "$fixture/builder-output")"
test "$(cat "$fixture/dependent-input-copy")" = retained
test "$(cat "$fixture/input-output-after-gc")" = retained
test ! -e "$(cat "$fixture/dead-path")"
printf 'HS-7 collector returns during live builder and preserves its inputs: PASS\n'
cleanup
trap - EXIT

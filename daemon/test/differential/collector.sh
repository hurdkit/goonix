#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
out=${1:-$root/.scratch/hs7-collector-differential}
if test -e "$out"; then chmod -R u+rwX "$out" 2>/dev/null || true; rm -rf "$out"; fi
mkdir -p "$out"
cxx=${GOONIX_CXX_DAEMON:-$root/.scratch/hs0-cxx-daemon}
hs=${GOONIX_HS_DAEMON:-$root/guix-daemon}
for daemon in "$cxx" "$hs"; do test -x "$daemon"; done
export GUILE_AUTO_COMPILE=0
cc -O2 -Wall -Wextra "$root/daemon/test/differential/gc-lock-holder.c" -o "$out/gc-lock-holder"
run_one() {
  name=$1 daemon=$2 fixture=$out/$name
  mkdir -p "$fixture/store" "$fixture/db" "$fixture/var" "$fixture/substituter-data"
  export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
  export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
  export GUIX_BINARY_SUBSTITUTE_URL="file://$fixture/substituter-data"
  export GUIX_TEST_SUBSTITUTE_URLS="$GUIX_BINARY_SUBSTITUTE_URL"
  export HS7_FIXTURE="$fixture" GUIX="$root/scripts/guix"
  goonix_start_capped "$root/pre-inst-env" "$daemon" --disable-chroot --listen="$GUIX_DAEMON_SOCKET" >"$out/$name.daemon.log" 2>&1
  pid=$GOONIX_TEST_PID
  daemon_scope=$GOONIX_TEST_SCOPE
  trap 'goonix_stop_capped "$pid" "$daemon_scope"' EXIT
  for i in $(seq 1 200); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
  test -S "$GUIX_DAEMON_SOCKET"
  goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile "$root/daemon/test/differential/collector-probe.scm" >"$out/$name.out" 2>"$out/$name.err"
  # Hold the same POSIX exclusive GC lock externally.  A live query must wait
  # until it is released, rather than observing roots during a collection.
  goonix_start_capped "$out/gc-lock-holder" "$fixture/var/gc.lock" >"$out/$name.lock-holder" 2>&1
  holder=$GOONIX_TEST_PID
  holder_scope=$GOONIX_TEST_SCOPE
  for i in $(seq 1 200); do grep -q held "$out/$name.lock-holder" && break; sleep .01; done
  grep -q held "$out/$name.lock-holder"
  goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile -c '(use-modules (guix store)) (let ((store (open-connection (getenv "GUIX_DAEMON_SOCKET")))) (live-paths store) (display "query-finished\n"))' >"$out/$name.locked-query" &
  query=$!
  sleep 1
  if ! kill -0 "$query" 2>/dev/null; then
    cat "$out/$name.locked-query"
    return 1
  fi
  test ! -s "$out/$name.locked-query"
  goonix_stop_capped "$holder" "$holder_scope"
  wait "$holder" 2>/dev/null || true
  wait "$query"
  grep -q query-finished "$out/$name.locked-query"
  goonix_stop_capped "$pid" "$daemon_scope"
  wait "$pid" 2>/dev/null || true
  trap - EXIT
  sqlite3 "$fixture/db/db.sqlite" 'pragma busy_timeout=10000; select path,hash,deriver,narSize from ValidPaths order by path; select * from Refs order by referrer,reference; select * from DerivationOutputs order by drv,id;' >"$out/$name.db"
  find "$fixture/store" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort >"$out/$name.files"
}
run_one cxx "$cxx"
run_one hs "$hs"
for suffix in out db files; do
  sed -E -e "s#$out/cxx/store#STORE#g" -e "s#$out/cxx/var#STATE#g" -e "s#$out/cxx#ROOT#g" -e 's#(STORE/|^[[:space:]]*)[[:alnum:]]{32}-#\1HASH-#g' "$out/cxx.$suffix" >"$out/cxx.$suffix.norm"
  sed -E -e "s#$out/hs/store#STORE#g" -e "s#$out/hs/var#STATE#g" -e "s#$out/hs#ROOT#g" -e 's#(STORE/|^[[:space:]]*)[[:alnum:]]{32}-#\1HASH-#g' "$out/hs.$suffix" >"$out/hs.$suffix.norm"
  if test "$suffix" = db -o "$suffix" = files; then sort -o "$out/cxx.$suffix.norm" "$out/cxx.$suffix.norm"; sort -o "$out/hs.$suffix.norm" "$out/hs.$suffix.norm"; fi
  diff -u "$out/cxx.$suffix.norm" "$out/hs.$suffix.norm"
done
printf 'HS-7 collector differential: PASS\n'
# Successful comparisons keep their normalized logs, not the copied stores.
chmod -R u+rwX "$out/cxx" "$out/hs" 2>/dev/null || true
rm -rf "$out/cxx" "$out/hs" "$out/gc-lock-holder"

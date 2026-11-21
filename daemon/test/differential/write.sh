#!/usr/bin/env bash
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
out=${1:-$root/hs3-write}
if test -e "$out"; then chmod -R u+rwX "$out" 2>/dev/null || true; rm -rf "$out"; fi
mkdir -p "$out"
probe=$root/daemon/test/differential/write-probe.scm
archive_probe=$root/daemon/test/differential/archive-probe.scm
cxx=${GOONIX_CXX_DAEMON:-$root/hs0-cxx-daemon}
hs=${GOONIX_HS_DAEMON:-$root/guix-daemon}
run_one() {
  name=$1; daemon=$2; fixture=$out/$name
  "$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
  mkdir -p "$fixture/input-tree/sub" "$fixture/config"
  cp "$root/tests/keys/openpgp/signing-key.sec" "$fixture/config/signing-key.sec"
  cp "$root/tests/keys/openpgp/signing-key.pub" "$fixture/config/signing-key.pub"
  chmod 0600 "$fixture/config/signing-key.sec"
  printf 'alpha\n' > "$fixture/input-tree/a"
  printf 'beta\n' > "$fixture/input-tree/sub/b"
  ln -s a "$fixture/input-tree/link"
  chmod 0555 "$fixture/input-tree/sub/b"
  printf 'flat payload\n' > "$fixture/flat.txt"
  export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db" GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket" HS3_ROOT="$fixture" GUIX_CONFIGURATION_DIRECTORY="$fixture/config" GUIX=/run/current-system/sw/bin/guix
  "$daemon" --disable-chroot --listen="$GUIX_DAEMON_SOCKET" >"$out/$name.log" 2>&1 &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true' EXIT
  for i in $(seq 1 200); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
  test -S "$GUIX_DAEMON_SOCKET"
  "$root/pre-inst-env" guile --no-auto-compile "$probe" >"$out/$name.out" 2>"$out/$name.err"
  "$root/pre-inst-env" guile --no-auto-compile "$archive_probe" >"$out/$name.archive.out" 2>"$out/$name.archive.err"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  trap - EXIT
  sqlite3 "$fixture/db/db.sqlite" 'pragma busy_timeout=10000; select path,hash,deriver,narSize from ValidPaths order by path; select * from Refs order by referrer,reference; select * from DerivationOutputs order by drv,id;' >"$out/$name.db"
}
run_one cxx "$cxx"
run_one hs "$hs"
for suffix in out err db archive.out archive.err; do
  if test "$suffix" = archive.err; then
    grep -v '^exporting path `' "$out/cxx.$suffix" >"$out/cxx.$suffix.filtered" || true
    cp "$out/hs.$suffix" "$out/hs.$suffix.filtered"
  else
    cp "$out/cxx.$suffix" "$out/cxx.$suffix.filtered"
    cp "$out/hs.$suffix" "$out/hs.$suffix.filtered"
  fi
  sed -E -e "s#$out/cxx/store#STORE#g" -e "s#$out/cxx/var#STATE#g" -e "s#$out/cxx#ROOT#g" -e 's#STORE/[[:alnum:]]{32}-#STORE/HASH-#g' -e 's/registration-time: [0-9][0-9]*/registration-time: TIME/g' "$out/cxx.$suffix.filtered" >"$out/cxx.$suffix.norm"
  sed -E -e "s#$out/hs/store#STORE#g" -e "s#$out/hs/var#STATE#g" -e "s#$out/hs#ROOT#g" -e 's#STORE/[[:alnum:]]{32}-#STORE/HASH-#g' -e 's/registration-time: [0-9][0-9]*/registration-time: TIME/g' "$out/hs.$suffix.filtered" >"$out/hs.$suffix.norm"
  if test "$suffix" = db; then sort -o "$out/cxx.$suffix.norm" "$out/cxx.$suffix.norm"; sort -o "$out/hs.$suffix.norm" "$out/hs.$suffix.norm"; fi
  cmp "$out/cxx.$suffix.norm" "$out/hs.$suffix.norm"
done
# The store path hash includes the absolute store prefix, so compare the
# actual item names only after normalizing each run's prefix.
for item in a.txt b.txt tree flat.txt; do
  c=$(find "$out/cxx/store" -maxdepth 1 -name "*-$item" -print -quit)
  h=$(find "$out/hs/store" -maxdepth 1 -name "*-$item" -print -quit)
  test -n "$c" && test -n "$h"
  diff -ru "$c" "$h"
done
printf 'HS-3 write differential: PASS\n'

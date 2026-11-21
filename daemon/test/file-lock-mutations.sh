#!/usr/bin/env bash
# Mutate a temporary copy of the daemon's own lock table. Each fault must be
# rejected by the same integration test, on the copied production sources.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
logs=${GOONIX_MUTATION_LOG_DIR:-$here/../../.scratch/file-lock-mutations}
mkdir -p "$logs"
run_fault() {
  local name=$1 expected=$2
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/goonix-lock-mutation-$name.XXXXXX")
  trap 'find "$tmp" -type d -exec chmod u+rwx {} + 2>/dev/null || true; rm -rf "$tmp"' RETURN
  mkdir "$tmp/daemon"
  cp -a "$here/../src" "$here/../cbits" "$tmp/daemon/"
  cp "$here/file-locks.hs" "$tmp/file-locks.hs"
  cp "$tmp/daemon/src/Goonix/Store/Files.hs" "$tmp/Files.hs.original"
  case $name in
    reader-closes)
      perl -0pi -e 's/            pure Nothing/            unsafePerformIO (closeFd (Fd fd)) `seq` pure Nothing/' \
        "$tmp/daemon/src/Goonix/Store/Files.hs"
      ;;
    busy-after-kill)
      # Deleting the Busy entry during masked acquisition cannot be observed.
      # Remove the final release deletion instead: every ordinary holder runs
      # it, and the final table-empty assertion must reject the stale entry.
      perl -0pi -e "s/\QcloseLock fd \`finally\` atomically (modifyTVar' fileLocks (Map.delete path))\E/closeLock fd/" \
        "$tmp/daemon/src/Goonix/Store/Files.hs"
      ;;
  esac
  if cmp -s "$tmp/Files.hs.original" "$tmp/daemon/src/Goonix/Store/Files.hs"; then
    echo "mutation did not change the lock table: $name" >&2
    return 1
  fi
  if goonix_run_capped ghc -threaded -O0 -outputdir "$tmp/obj" -o "$tmp/file-locks" \
      -i"$tmp/daemon/src" "$tmp/file-locks.hs" "$tmp/daemon/cbits/files.c" \
      "$tmp"/daemon/src/Goonix/*.hs "$tmp"/daemon/src/Goonix/Store/*.hs \
      "$tmp"/daemon/src/Goonix/Build/*.hs -lgcrypt -lsqlite3 -lz -lbz2 \
      >"$logs/$name-build.log" 2>&1 && \
      goonix_run_capped "$tmp/file-locks" "$tmp/store" >"$logs/$name.log" 2>&1; then
    echo "mutation unexpectedly passed: $name" >&2
    return 1
  fi
  if ! grep -F "$expected" "$logs/$name.log"; then
    echo "mutation failed before the expected assertion: $name" >&2
    return 1
  fi
  echo "mutation rejected as expected: $name"
}
run_fault reader-closes 'lock still held after seven readers left'
run_fault busy-after-kill 'table empty after single holder'
echo 'lock-table mutations: PASS (both rejected)'

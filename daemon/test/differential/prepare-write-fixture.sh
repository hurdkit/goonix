#!/usr/bin/env bash
# goonix: fresh empty store for a write run; no existing store is reused.
set -eu
root=$1
if test -e "$root"; then
  chmod -R u+rwX "$root" 2>/dev/null || true
  rm -rf "$root"
fi
mkdir -p "$root/store" "$root/db" "$root/var/gcroots" "$root/var/profiles" "$root/var/temproots"
sqlite3 "$root/db/db.sqlite" < "$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)/guix/store/schema.sql"
printf 7 > "$root/db/schema"
printf '%s\n' "$root/store" > "$root/store-path"

#!/usr/bin/env bash
# goonix: one store/database root belongs to one build tree (DECISIONS 92).
set -euo pipefail
root=$1 builddir=$2
mkdir -p "$root"
if [ -f "$root/.owner" ]; then
  owner=$(cat "$root/.owner")
  if [ "$owner" != "$builddir" ]; then
    printf 'goonix test root %s belongs to %s, not %s\n' \
      "$root" "$owner" "$builddir" >&2
    exit 1
  fi
else
  printf '%s\n' "$builddir" > "$root/.owner"
fi

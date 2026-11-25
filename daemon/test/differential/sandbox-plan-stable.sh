#!/usr/bin/env bash
# A sandbox plan is written once before c_spawn_sandbox and never truncated or
# rewritten after it.  The actual C++ parser checks the encoded full plan and
# refuses a truncated one.  The source boundary check fails at 10a8d4f01c1,
# whose KVM handling rewrote the same plan after spawning its reader.
set -euo pipefail
root=${1:-$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)}
here="$root/daemon/test/differential"
. "$root/daemon/test/lib.sh"
command -v ghc >/dev/null 2>&1 || { echo "no ghc"; exit 2; }
test -x "$root/guix-sandbox" || { echo "build guix-sandbox first"; exit 2; }
out=$(mktemp -d /tmp/sandbox-plan-stable.XXXXXX)
trap 'rm -rf "$out"' EXIT
goonix_run_capped ghc -O0 -XGHC2024 -outputdir "$out/obj" -o "$out/probe" \
  -i"$root/daemon/src" "$here/sandbox-plan-stable.hs"
source=${2:-$root/daemon/src/Goonix/Build/Engine.hs}
goonix_run_capped "$out/probe" "$root/guix-sandbox" "$source"

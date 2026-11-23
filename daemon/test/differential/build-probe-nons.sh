#!/usr/bin/env bash
# Isolate the stress-gate build hang WITHOUT a namespace/bind mounts (runs on any
# host, e.g. z2build): the daemon uses a scratch store via env vars, exactly like
# root-ci-substitute.sh.  Run the minimal build probe (add-to-store + derivation +
# build-derivations) with GUILE_LOAD_COMPILED_PATH set, with either the noisy
# substituting helper or the silent one, to isolate whether the noisy helper's
# substitution is what makes the gate's build clients hang.
#   build-probe-nons.sh <work> <noisy|silent> [root]
set -uo pipefail
work=${1:?work}; mode=${2:?mode}; root=${3:-$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)}
here="$root/daemon/test/differential"
sub="$work/buildprobe"
mkdir -p "$sub/store" "$sub/db" "$sub/var" "$sub/log" "$sub/etc" "$sub/cache" "$sub/tmp"
sqlite3 "$sub/db/db.sqlite" < "$root/guix/store/schema.sql"
printf 7 > "$sub/db/schema"
devinfo=$(cd "$root" && nix develop .#default -c bash -c 'echo "GLP=$GUILE_LOAD_PATH"; echo "GLCP=$GUILE_LOAD_COMPILED_PATH"')
dev_glp=$(echo "$devinfo" | grep '^GLP=' | sed 's/^GLP=//')
dev_glcp=$(echo "$devinfo" | grep '^GLCP=' | sed 's/^GLCP=//')
bash_abs=$(command -v bash); dev_path="$PATH"
case "$mode" in
  noisy) body="$here/stress-noisy-helper.sh";;
  silent) body="$here/substitute-silent-helper.sh";;
  none) body="";;
  *) echo "bad mode $mode"; exit 2;;
esac
helper="$sub/helper.wrapper"
guix_env=()
if test -n "$body"; then
  { printf '#!%s\n' "$bash_abs"; printf 'export PATH=%s\n' "$dev_path"; cat "$body"; } > "$helper"
  chmod +x "$helper"
  guix_env=(GUIX="$helper")
fi
# No --build-users-group: run as the invoking (non-root) user so this needs no
# root and no bind mounts; the build uses a user namespace as the host user.
# The substitution hang under test happens BEFORE the sandbox build, so it is
# reproduced regardless of whether the sandbox build itself succeeds.
env -i TMPDIR="$sub/tmp" LC_ALL=C.UTF-8 PATH=/nonexistent "${guix_env[@]}" \
  NIX_STORE_DIR="$sub/store" GUIX_DATABASE_DIRECTORY="$sub/db" \
  GUIX_STATE_DIRECTORY="$sub/var" GUIX_LOG_DIRECTORY="$sub/log" \
  GUIX_DAEMON_SOCKET="$sub/socket" \
  "$root/guix-daemon" --max-jobs=2 --substitute-urls="" \
  --no-substitutes --no-offload --listen="$sub/socket" >"$sub/daemon.log" 2>&1 &
dpid=$!
for i in $(seq 1 300); do test -S "$sub/socket" && break; kill -0 "$dpid" 2>/dev/null || break; sleep .05; done
test -S "$sub/socket" || { echo "daemon did not listen"; head -5 "$sub/daemon.log"; exit 1; }
timeout 60 env -i LC_ALL=C.UTF-8 PATH=/nonexistent \
  NIX_STORE_DIR="$sub/store" GUIX_DATABASE_DIRECTORY="$sub/db" \
  GUIX_STATE_DIRECTORY="$sub/var" GUIX_LOG_DIRECTORY="$sub/log" \
  GUIX_DAEMON_SOCKET="$sub/socket" XDG_CACHE_HOME="$sub/cache" \
  GUILE_LOAD_PATH="$root:$dev_glp" GUILE_LOAD_COMPILED_PATH="$root:$dev_glcp" GUIX_UNINSTALLED=1 \
  "$root/guile" --no-auto-compile "$here/build-probe.scm" "$sub/socket" >"$sub/build-probe.log" 2>&1
rc=$?
echo "MODE=$mode BUILD_PROBE_RC=$rc"
cat "$sub/build-probe.log"
kill "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null
exit $rc
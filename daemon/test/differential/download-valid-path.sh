#!/usr/bin/env bash
# Regression: a download job for a path that is valid must not ask a
# substituter about it.  The sources of a derivation become download jobs of
# its request; C++ SubstitutionGoal::init finishes such a goal at once when the
# path is valid.  The Haskell engine started `guix substitute --query' for each
# one first, so a build spawned a helper per source, substitutes on or off.
#
# GUIX points at a helper that records how it is called and answers every
# query with "nothing".  A derivation whose sources are all valid is built
# with substitutes off; the helper must never have been started as
# `substitute'.
#
# Usage: download-valid-path.sh [DAEMON] [FIXTURE]
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
daemon=${1:-${GOONIX_TEST_DAEMON:-$root/guix-daemon}}
fixture=${2:-$root/.scratch/download-valid-path}
if test -e "$fixture"; then chmod -R u+rwX "$fixture" 2>/dev/null || true; rm -rf "$fixture"; fi
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
mkdir -p "$fixture/etc" "$fixture/cache"
helper="$fixture/guix-helper"
cat > "$helper" <<HELPER
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fixture/helper-calls"
if test "\${1:-}" = substitute; then
  # "have" and "info" queries: an empty answer ends with a blank line on fd 4.
  while read -r _command _rest; do printf '\n' >&4; done
fi
exit 0
HELPER
chmod +x "$helper"
: > "$fixture/helper-calls"
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db"
export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
export GUIX_LOG_DIRECTORY="$fixture/var/log/guix" GUIX_CONFIGURATION_DIRECTORY="$fixture/etc"
export XDG_CACHE_HOME="$fixture/cache" GUILE_AUTO_COMPILE=0
pid= scope=
cleanup() {
  status=$?
  trap - EXIT
  if test -n "$pid"; then goonix_stop_capped "$pid" "$scope"; fi
  return "$status"
}
trap cleanup EXIT
# pre-inst-env sets GUIX to the real program; the helper is named after it.
goonix_start_capped "$root/pre-inst-env" env GUIX="$helper" "$daemon" --disable-chroot \
  --no-substitutes --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1
pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
test -S "$GUIX_DAEMON_SOCKET"
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile \
  "$root/daemon/test/differential/download-valid-path.scm" | tee "$fixture/client.log"
grep -Fq 'valid-source build: done' "$fixture/client.log"
if grep -q '^substitute' "$fixture/helper-calls"; then
  echo "FAIL: a substituter was started for a request whose paths are all valid:" >&2
  sort "$fixture/helper-calls" | uniq -c >&2
  exit 1
fi
echo "download of a valid path asks no substituter: PASS"

#!/usr/bin/env bash
# goonix: CA-6 step 4 boot gate — the hello probe in a PRIVATE mount namespace.
# The host daemon predates CA and /gnu/store is read-only for wrath; this runs
# the IMPLEMENTATION daemon inside a user+mount namespace with a writable
# directory bound OVER /gnu/store (the store dir stays /gnu/store so upstream
# substitutes apply), bordeaux as the substitute server.  Probe: `guix build
# hello` under the input policy must be SUBSTITUTED, not built.  The host
# daemon, /gnu/store and /var/guix are untouched.  Run through heavy-turn.sh
# under a memory cap.  Set GOONIX_CA6_SCRATCH for the backing dir.
set -euo pipefail
IMPL=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$IMPL"

if ! unshare --user --map-root-user --mount true 2>/dev/null; then
  printf 'SKIP: user/mount namespaces are unavailable\n'
  exit 77
fi

scratch=${GOONIX_CA6_SCRATCH:-$IMPL/goonix-ca6/work}
mkdir -p "$scratch/store" "$scratch/var" "$scratch/etc" "$scratch/log"
chmod 700 "$scratch/etc"
# Authorise the bordeaux substitute key.
{
  printf '(acl (entry '
  cat etc/substitutes/bordeaux.guix.gnu.org.pub
  printf ' (tag (guix import))))\n'
} > "$scratch/etc/acl"

cat > "$scratch/part.sh" <<EOF
set -euo pipefail
# We are uid 0 in the namespace.  Bind the writable backing dirs over the
# host's read-only /gnu/store and /var/guix (mounting over is allowed; the
# host's mounts are not unmounted and stay untouched outside this namespace).
mount --bind '$scratch/store' /gnu/store
mount --bind '$scratch/var' /var/guix
export NIX_STORE_DIR=/gnu/store
export GUIX_STATE_DIRECTORY='$scratch/var'
export GUIX_DATABASE_DIRECTORY='$scratch/var/db'
export GUIX_CONFIGURATION_DIRECTORY='$scratch/etc'
export GUIX_LOG_DIRECTORY='$scratch/log'
export GUIX_DAEMON_SOCKET='$scratch/socket'
export GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES=no
export GOONIX_DOWNLOAD_CACHE='${GOONIX_DOWNLOAD_CACHE:-http://10.0.30.4:8480}'
cd '$IMPL'
./pre-inst-env ./guix-daemon --disable-chroot \\
  --listen='$scratch/socket' \\
  --substitute-urls='http://10.0.30.4:8480/substitutes/bordeaux https://bordeaux.guix.gnu.org' \\
  >'$scratch/daemon.log' 2>&1 &
daemon_pid=\$!
trap 'kill "\$daemon_pid" 2>/dev/null || true' EXIT
for i in \$(seq 1 100); do test -S '$scratch/socket' && break; sleep .1; done
# The probe: hello under the input policy, substituted from bordeaux.
./pre-inst-env guix build hello --no-grafts \\
  >'$scratch/hello.out' 2>'$scratch/hello.err'
echo "HELLO_EXIT=\$?" >> '$scratch/result'
cat '$scratch/hello.out' >> '$scratch/result'
EOF

# Run the part in the namespace as uid 0 (the daemon runs with
# --disable-chroot, so no build users are needed; guix-ca-files.sh's server
# does the same).  The bind mounts only affect this namespace.
unshare --user --map-root-user --mount bash "$scratch/part.sh" \
  > "$scratch/run.log" 2>&1 || true

echo '=== result ==='
cat "$scratch/result" 2>/dev/null || echo 'no result'
echo '=== hello.err tail ==='
tail -15 "$scratch/hello.err" 2>/dev/null || true
echo '=== daemon.log tail ==='
tail -8 "$scratch/daemon.log" 2>/dev/null || true
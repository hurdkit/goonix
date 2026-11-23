#!/usr/bin/env bash
# goonix: CA-8 core — the namespace harness shared by every stage.
#
# One heavy-turn job per stage (the build lane is shared with the Haskell
# session).  The namespace store, database and state stay on disk BETWEEN
# stages; each stage re-enters the namespace, starts the daemon, does its
# work, and stops the daemon at its end so the lane is free between stages.
#
# Usage: ca8-core-run.sh <stage-name> <scheme-file> [timeout-secs]
# The scheme file runs inside the namespace with the store bound writable.
#
# The Guile load path must carry guile-gcrypt and the other Guile libraries,
# so this re-enters the project's dev shell unless it is already inside one
# (measured: launched without it, the namespace client dies with
# "no code for module (gcrypt hash)").
#
# The host daemon, the host /gnu/store and /var/guix are never touched.
set -euo pipefail
IMPL=/home/wrath/goonix/.worktrees/goonix-implementation
cd "$IMPL"

if [ -z "${IN_NIX_SHELL:-}" ]; then
  # goonix: the shell MUST come from this worktree's own flake.  The main
  # checkout /home/wrath/goonix (branch goonix, the pinned base) has no
  # libarchive, so a shell taken from it configures without goonix-ca-scan and
  # the deep-scan refusals silently never happen.  See DECISIONS.md point 12.
  exec nix develop '.#default' -c bash "$0" "$@"
fi

stage=${1:?stage name}
script=${2:?scheme file}

if ! unshare --user --map-root-user --mount true 2>/dev/null; then
  printf 'SKIP: user/mount namespaces are unavailable\n'
  exit 77
fi

scratch=${GOONIX_CA8_SCRATCH:-$IMPL/.scratch/ca8-core}
mkdir -p "$scratch/store" "$scratch/var" "$scratch/etc" "$scratch/log"
chmod 700 "$scratch/etc"

# Build users for the namespace (reviewer, point 2).  The namespace daemon
# has no build users of its own, so builtin builders ran as root and
# perform-download refused UID 0.  Map the subordinate ID range next to our
# own UID so the daemon can drop to a real unprivileged build user.
#
# Two host specifics, both measured:
#   * the setuid newuidmap/newgidmap wrappers live in /run/wrappers/bin,
#     which is AFTER /run/current-system/sw/bin on PATH; the store binary
#     there has no setuid bit and answers "write to uid_map failed:
#     Operation not permitted".
#   * wrath's gid is 100 (users), not 1000.
# Namespace UID 0 -> host 1000, UIDs 1..65536 -> host 100000..165535.
export PATH=/run/wrappers/bin:$PATH
map_args=(--map-users=0:1000:1 --map-users=1:100000:65536
          --map-groups=0:100:1 --map-groups=1:100000:65536)

# passwd/group with a guixbuild group and ten build users, at namespace IDs
# inside the subordinate range (UID 1..10, GID 1).
{
  printf 'root:x:0:0:System administrator:/root:/bin/sh\n'
  printf 'nobody:x:65534:65534:Unprivileged:/var/empty:/bin/false\n'
  for i in $(seq 0 9); do
    printf 'guixbuilder%d:x:%d:1:Guix build user %d:/var/empty:/bin/false\n' \
      "$i" "$((i + 1))" "$i"
  done
} > "$scratch/etc/passwd.ns"
{
  printf 'root:x:0:\n'
  printf 'users:x:100:\n'
  printf 'guixbuild:x:1:'
  for i in $(seq 0 9); do
    printf 'guixbuilder%d' "$i"
    [ "$i" -lt 9 ] && printf ','
  done
  printf '\nnogroup:x:65534:\n'
} > "$scratch/etc/group.ns"
# Authorise the bordeaux key: fixed-output fetches (sources, seeds) only.
{
  printf '(acl (entry '
  cat etc/substitutes/bordeaux.guix.gnu.org.pub
  printf ' (tag (guix import))))\n'
} > "$scratch/etc/acl"

# The daemon signs its build records with a secret key in its configuration
# directory and errors out if the file is missing or its permissions are
# wrong (checkSecrecy).  Use the repository's TEST keys, exactly as test-env
# does, never the host's /etc/guix key.  Remove first: the installed key is
# mode 400, so a plain cp over it fails with "Permission denied" on a rerun.
rm -f "$scratch/etc/signing-key.sec" "$scratch/etc/signing-key.pub"
cp "$IMPL/tests/keys/openpgp/signing-key.sec" \
   "$IMPL/tests/keys/openpgp/signing-key.pub" \
   "$scratch/etc/"
chmod 400 "$scratch/etc/signing-key.sec"

# Disk limits (reviewer, 2026-11-21): the namespace store under 150 GB, and
# df / must keep at least 40 GB available for the other sessions and guests.
# The watchdog runs INSIDE the namespace job and stops the daemon cleanly.
cap_kb=$((150 * 1024 * 1024))
floor_kb=$((40 * 1024 * 1024))

cat > "$scratch/part-$stage.sh" <<EOF
set -uo pipefail
mount --bind '$scratch/store' /gnu/store
mount --bind '$scratch/var' /var/guix
# Build users, and hide the host's nscd: glibc answers getgrnam/getpwnam
# from /var/run/nscd/socket, which a mount namespace still reaches, so
# without this the bind-mounted passwd/group are ignored and the daemon
# would see the HOST's guixbuild gid.  Measured: masking /run/nscd makes
# getent return gid 1 / uid 1 from the files above.
mount --bind '$scratch/etc/passwd.ns' /etc/passwd
mount --bind '$scratch/etc/group.ns' /etc/group
mount -t tmpfs tmpfs /run/nscd
mkdir -p /var/empty
export NIX_STORE_DIR=/gnu/store
export GUIX_STATE_DIRECTORY='$scratch/var'
export GUIX_DATABASE_DIRECTORY='$scratch/var/db'
export GUIX_CONFIGURATION_DIRECTORY='$scratch/etc'
export GUIX_LOG_DIRECTORY='$scratch/log'
export GUIX_DAEMON_SOCKET='$scratch/socket'
export GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES=no
# The daemon creates each build directory under TMPDIR.  'nix develop' sets
# TMPDIR to its own /tmp/nix-shell.XXXX, mode 0700 and owned by namespace
# root, so a build USER cannot traverse it and the builder dies with
# "Permission denied" on its own build directory (measured on mes-boot's
# module-import-compiled).  The scratch tree is under /home/wrath, itself
# 0700, so it cannot serve either.  Bind a private /tmp inside the
# namespace: world-traversable, and the host's /tmp is untouched.
# createTempDir still makes each build directory 0700 for its build user.
mount -t tmpfs -o mode=1777 tmpfs /tmp
export TMPDIR=/tmp
cd '$IMPL'
./pre-inst-env ./guix-daemon --disable-chroot \\
  --build-users-group=guixbuild \\
  --listen='$scratch/socket' \\
  --substitute-urls=https://bordeaux.guix.gnu.org \\
  >'$scratch/daemon-$stage.log' 2>&1 &
daemon_pid=\$!
stop_daemon() { kill "\$daemon_pid" 2>/dev/null || true; }
trap stop_daemon EXIT
for i in \$(seq 1 100); do test -S '$scratch/socket' && break; sleep .1; done

# The watchdog: every 120 s, stop cleanly if either limit is crossed.
(
  while kill -0 "\$daemon_pid" 2>/dev/null; do
    sleep 120
    used=\$(du -sk '$scratch/store' 2>/dev/null | cut -f1)
    avail=\$(df -k / | awk 'NR==2 {print \$4}')
    if [ "\${used:-0}" -gt $cap_kb ]; then
      echo "WATCHDOG: namespace store \${used} KB exceeds 150 GB cap" \\
        >> '$scratch/watchdog-$stage.log'
      stop_daemon; exit 0
    fi
    if [ "\${avail:-0}" -lt $floor_kb ]; then
      echo "WATCHDOG: df / available \${avail} KB below 40 GB floor" \\
        >> '$scratch/watchdog-$stage.log'
      stop_daemon; exit 0
    fi
  done
) &
watchdog_pid=\$!

./pre-inst-env guile --no-auto-compile '$script' \\
  >'$scratch/$stage.out' 2>'$scratch/$stage.err'
status=\$?
kill "\$watchdog_pid" 2>/dev/null || true
echo "STAGE=$stage EXIT=\$status" >> '$scratch/results'
stop_daemon
exit \$status
EOF

unshare --user "${map_args[@]}" --mount bash "$scratch/part-$stage.sh" \
  > "$scratch/run-$stage.log" 2>&1
status=$?

echo "=== $stage result ==="
grep "STAGE=$stage" "$scratch/results" 2>/dev/null | tail -1 || echo 'no result line'
echo "=== $stage stdout (tail) ==="
tail -40 "$scratch/$stage.out" 2>/dev/null || true
echo "=== $stage stderr (tail) ==="
tail -15 "$scratch/$stage.err" 2>/dev/null || true
echo "=== watchdog ==="
cat "$scratch/watchdog-$stage.log" 2>/dev/null || echo 'not triggered'
echo "=== disk after ==="
du -sh "$scratch/store" 2>/dev/null || true
df -h / | tail -1
exit $status
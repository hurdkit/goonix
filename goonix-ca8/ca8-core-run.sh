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
IMPL=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
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
# The IDs are read from the HOST AT RUN TIME, never hardcoded.  This runner
# previously hardcoded the laptop's (uid 1000, gid 100, subuid 100000,
# /run/wrappers/bin) and died silently on zergling2, which is hurdkit
# (uid 1003, gid 1003) on Ubuntu 24.04 WSL with subuid 231072:65536 AND
# 100000:65536 but subgid ONLY 231072:65536, and newuidmap/newgidmap in
# /usr/bin with no /run/wrappers at all.  Same logic as goonix-ca6/run.sh,
# which is proven on both machines; taking the FIRST entry of each file
# handles both.
host_uid=$(id -u)
host_gid=$(id -g)
host_user=$(id -un)
sub_uid=$(awk -F: -v u="$host_user" '$1==u {print $2; exit}' /etc/subuid)
sub_uid_count=$(awk -F: -v u="$host_user" '$1==u {print $3; exit}' /etc/subuid)
sub_gid=$(awk -F: -v u="$host_user" '$1==u {print $2; exit}' /etc/subgid)
sub_gid_count=$(awk -F: -v u="$host_user" '$1==u {print $3; exit}' /etc/subgid)
: "${sub_uid:?no /etc/subuid entry for $host_user}"
: "${sub_gid:?no /etc/subgid entry for $host_user}"
# newuidmap/newgidmap must be the SETUID ones.  NixOS puts the wrappers in
# /run/wrappers/bin, ahead of the store binary that has no setuid bit and
# answers "write to uid_map failed: Operation not permitted"; Ubuntu's
# /usr/bin/newuidmap is already setuid.
if [ -x /run/wrappers/bin/newuidmap ]; then
  export PATH=/run/wrappers/bin:$PATH
fi
command -v newuidmap >/dev/null || { echo 'newuidmap not on PATH' >&2; exit 1; }
command -v newgidmap >/dev/null || { echo 'newgidmap not on PATH' >&2; exit 1; }
echo "MAP: uid=$host_uid gid=$host_gid subuid=$sub_uid:$sub_uid_count subgid=$sub_gid:$sub_gid_count newuidmap=$(command -v newuidmap)"
# The ranges are written by explicit newuidmap/newgidmap on the parked child
# below, not by unshare --map-users: that flag alone left the child unmapped.

# passwd/group with a guixbuild group and ten build users, at namespace IDs
# inside the subordinate range (UID 1..10, GID 1).  Their home is a directory
# in our own scratch tree, not /var/empty: on Ubuntu /var is root-owned and
# cannot be written even as namespace root (measured, job ca6-z2-counted2).
mkdir -p "$scratch/var-empty"
{
  printf 'root:x:0:0:System administrator:/root:/bin/sh\n'
  printf 'nobody:x:65534:65534:Unprivileged:%s:/bin/false\n' "$scratch/var-empty"
  for i in $(seq 0 9); do
    printf 'guixbuilder%d:x:%d:1:Guix build user %d:%s:/bin/false\n' \
      "$i" "$((i + 1))" "$i" "$scratch/var-empty"
  done
} > "$scratch/etc/passwd.ns"
{
  printf 'root:x:0:\n'
  printf 'users:x:%d:\n' "$host_gid"
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
# Mask nscd only when the host has it.  NixOS runs nscd; Ubuntu 24.04 on
# zergling2 has no /run/nscd and the mount fails with "mount point does not
# exist" (measured, job ca8-core-fresh3).  Create it when absent so the mask
# still applies if nscd appears later.
if [ -d /run/nscd ] || mkdir -p /run/nscd 2>/dev/null; then
  mount -t tmpfs tmpfs /run/nscd 2>/dev/null || true
fi
# `mkdir -p /var/empty` fails with "Permission denied" even as namespace root
# on Ubuntu, where /var is root-owned on the host filesystem.  The build users'
# home is $scratch/var-empty instead; this is best-effort only.
mkdir -p /var/empty 2>/dev/null || true
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

# Enter the namespace with a PARK-AND-MAP handshake, as goonix-ca6/run.sh does.
# `unshare --map-users=...` alone left the child UNMAPPED on zergling2: every
# mount in the part script failed with "must be superuser to use mount" and
# /run/nscd did not exist (job ca8-core-fresh3, measured in run-stage1.log).
# The child parks until explicit newuidmap/newgidmap have written BOTH ranges,
# then runs the part script; without the handshake it mounts as an unmapped uid.
rm -f "$scratch/ns-go" "$scratch/ns-pid"
unshare --user --mount bash -c '
  echo "$$" > "$1"
  for i in $(seq 1 600); do [ -e "$2" ] && break; sleep .1; done
  [ -e "$2" ] || { echo "no maps go-ahead" >&2; exit 1; }
  exec bash "$3"
' _ "$scratch/ns-pid" "$scratch/ns-go" "$scratch/part-$stage.sh" \
  > "$scratch/run-$stage.log" 2>&1 &
ns_job=$!
ns_pid=''
for i in $(seq 1 300); do
  ns_pid=$(cat "$scratch/ns-pid" 2>/dev/null | head -1)
  [ -n "$ns_pid" ] && break
  sleep .1
done
if [ -z "$ns_pid" ]; then
  echo "namespace child did not start; see run-$stage.log" >&2
  cat "$scratch/run-$stage.log" >&2
  exit 1
fi
newuidmap "$ns_pid" 0 "$host_uid" 1 1 "$sub_uid" "$sub_uid_count"
newgidmap "$ns_pid" 0 "$host_gid" 1 1 "$sub_gid" "$sub_gid_count"
echo "MAPS INSTALLED for pid $ns_pid"
: > "$scratch/ns-go"
wait "$ns_job"
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
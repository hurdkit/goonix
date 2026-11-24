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

# The scratch path MUST be absolute, and this is checked HERE - at the top,
# before the prepare build, before any daemon, in seconds rather than after 39
# minutes of compiling.  Every scratch-derived path below is interpolated into
# the namespace script verbatim and the daemon validates them: given a relative
# scratch it exits with
#   error: not an absolute path: `.scratch/<name>/log'
# so it never listens, the 10 s socket wait gives up, and guile reports
#   &store-connection-error file: ".scratch/<name>/socket" errno: 2
# which reads like a daemon crash rather than a bad argument.  Measured on
# z2-ca8-stage1-counted2: STAGE=stage1 EXIT=1, 0 store items, 0 build events,
# stage1.out empty, and that one line in daemon-stage1.log.  Refuse instead of
# silently resolving: the caller meant a specific tree, and guessing which one
# (this worktree? its cwd?) could wipe or write the wrong store.
case "${GOONIX_CA8_SCRATCH:-$IMPL/.scratch/ca8-core}" in
  /*) ;;
  *) echo "REFUSE: GOONIX_CA8_SCRATCH must be an absolute path, not '${GOONIX_CA8_SCRATCH}' (the daemon rejects relative paths)" >&2
     exit 1 ;;
esac

# goonix: a gate must run on a COMPILED tree.  This runner starts guile with
# --no-auto-compile, so an unbuilt tree is interpreted - a different load path
# that can fail on upstream macro hygiene (jq/oniguruma, DECISIONS 37).  Refuse
# before any daemon starts.  gate-lib.sh lives in goonix-ca6/ and is shared.
source "$IMPL/goonix-ca6/gate-lib.sh"

# PREPARE first when the tree is not built, exactly as goonix-ca6/z2-counted.sh
# does.  A DEDICATED per-job worktree (the lanes session's per-job submission) is
# created fresh at the requested commit, so it has no configure output and no
# .go files: asserting the precondition alone made every such job refuse with
# "cannot read GOBJECTS from make" (measured, goonix-ca8-point1-v7).  On a warm
# mirror this is a no-op, so the laptop path is unchanged.  GOONIX_CA8_PREPARE=0
# opts out for a caller that has already prepared the tree itself.
if [ "${GOONIX_CA8_PREPARE:-1}" = 1 ]; then
  if ! goonix_gate_require_compiled "$IMPL" >/dev/null 2>&1; then
    echo '=== prepare the tree (fresh worktree: configure + make) ==='
    if ! bash "$IMPL/goonix-ca6/prepare-tree.sh" \
         "${Z2_JOB_CORES:-${GOONIX_GATE_JOBS:-4}}" "$IMPL"; then
      echo 'PREPARE FAILED' >&2
      exit 1
    fi
  fi
fi
goonix_gate_require_compiled "$IMPL" || exit 1

if ! unshare --user --map-root-user --mount true 2>/dev/null; then
  printf 'SKIP: user/mount namespaces are unavailable\n'
  exit 77
fi

scratch=${GOONIX_CA8_SCRATCH:-$IMPL/.scratch/ca8-core}
# Absolute-path guard already ran at the top of this script, before prepare.

# GOONIX_CA8_FRESH=1 makes this the COUNTED run: the gate's claim is that the
# seeds and the ladder build content-addressed FROM A WIPED STORE, so a run
# that finds items already present proves only the tail (DECISIONS 57).
# Same wipe as goonix-ca6/run.sh:34-48, whose recipe is proven: store items are
# mode 555, so a plain `rm -rf' cannot unlink their children and fails with
# "Permission denied" even though we own them (measured, CA-6 counted run 15).
# Make the tree writable first.  This touches only our own scratch tree.
#
# No seed restore step, unlike CA-6: stage1's PASS 1 realises every fixed-output
# derivation of the chain itself, with substitutes on, so the wipe IS the
# reseed.  etc/ (the signing keys and the ACL) is deliberately NOT wiped: it is
# harness configuration, not store state, and the daemon needs it to start.
if [ "${GOONIX_CA8_FRESH:-0}" = 1 ]; then
  echo "FRESH: wiping $scratch/store, $scratch/var and $scratch/log (counted run)"
  chmod -R u+w "$scratch/store" "$scratch/var" "$scratch/log" 2>/dev/null || true
  rm -rf "$scratch/store" "$scratch/var" "$scratch/log"
  mkdir -p "$scratch/store" "$scratch/var" "$scratch/log"
  echo "FRESH: store items after wipe: $(ls "$scratch/store" | wc -l)"
fi

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

# CPU budget (lanes USAGE.md): "A command which starts a Nix/Guix build daemon
# must also give it an explicit --cores and --max-jobs within the same budget."
# guix-daemon does NOT read NIX_CONFIG (verified: no reference in nix/), and its
# defaults are max-jobs UNLIMITED and cores AUTO-DETECTED, so on zergling2 it
# would see 24 host cores under a 4-core quota and thrash.  z2run exports
# Z2_JOB_CORES; on the laptop the build lane's own cap applies.
daemon_cores=${Z2_JOB_CORES:-${GOONIX_GATE_JOBS:-4}}
daemon_jobs=${GOONIX_DAEMON_MAX_JOBS:-1}
case "$daemon_cores" in ''|*[!0-9]*) echo "bad core count: $daemon_cores" >&2; exit 1;; esac
[ "$daemon_cores" -ge 1 ] || { echo 'core count must be >= 1' >&2; exit 1; }
echo "DAEMON_BUDGET cores=$daemon_cores max-jobs=$daemon_jobs"

cat > "$scratch/part-$stage.sh" <<EOF
set -uo pipefail
# Job isolation check, BEFORE any mount and before the daemon starts.  The
# runner enters a private PID namespace after installing the ID maps, so this
# script must be PID 1 of its own namespace; otherwise the daemon's build-user
# cleanup kill(-1, SIGKILL) reaches other jobs' builders on the host (goonix
# DECISIONS 30).  Refuse rather than run unisolated.  Regression: revert the
# runner's 'exec unshare --pid --fork --kill-child' to 'exec bash' and this
# prints a PID other than 1 and exits non-zero (goonix-ca6/pid-ns-check.sh).
echo "PID_NS_CHECK pid=\$\$ ns=\$(readlink /proc/self/ns/pid)"
if [ "\$\$" != 1 ]; then
  echo "REFUSING: not PID 1 of a private PID namespace (pid=\$\$);" \\
       "the runner must exec unshare --pid --fork --kill-child after the maps" >&2
  echo "STAGE=$stage EXIT=1" >> '$scratch/results'
  exit 1
fi
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
# 'mkdir -p /var/empty' fails with "Permission denied" even as namespace root
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
  --cores=$daemon_cores --max-jobs=$daemon_jobs \\
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
  # Job isolation (reviewer, 2026-11-23; lanes DECISIONS "Job isolation goes
  # into the committed runners").  Private PID namespace INSIDE the mapping
  # boundary newuidmap/newgidmap just installed.  The daemon build-user cleanup
  # does kill(-1, SIGKILL): without this it reaches every process of the leased
  # uid on the HOST, and it killed the builders of another job mid-CA-8 (goonix
  # DECISIONS 30).  --fork is required by --pid, --kill-child ties the part
  # script lifetime to this child.  It must come AFTER the maps - a PID
  # namespace above the user namespace breaks the handshake outright
  # (measured: "Target process is owned by a different user").  The part script
  # refuses to start the daemon unless it is PID 1, so this cannot silently
  # regress.
  exec unshare --pid --fork --kill-child -- bash "$3"
' _ "$scratch/ns-pid" "$scratch/ns-go" "$scratch/part-$stage.sh" \
  > "$scratch/run-$stage.log" 2>&1 &
ns_job=$!
ns_pid=''
for i in $(seq 1 300); do
  # || true: pipefail + a missing pid file would abort the run under set -e.
  ns_pid=$(cat "$scratch/ns-pid" 2>/dev/null | head -1 || true)
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
# goonix: `wait` must not abort the script under `set -e`.  A FAILING stage is
# the normal way a gate reports a failure, and a bare `wait` returned its status
# straight to set -e, so the script died here - before the diagnostic tails and
# before the explicit exit below.  Capture the status instead.
status=0
wait "$ns_job" || status=$?

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

# goonix: exit with the STAGE'S OWN verdict, so a failed gate fails the unit
# that ran it (reviewer, DECISIONS 37).  The part script appends
# "STAGE=<name> EXIT=<status>" to results; prefer that recorded verdict over the
# namespace child's status, and treat a missing verdict as a failure.
stage_exit=$(grep -o "^STAGE=$stage EXIT=[0-9]*" "$scratch/results" 2>/dev/null \
             | tail -1 | sed 's/.*EXIT=//' || true)
if [ -n "$stage_exit" ]; then
  status=$stage_exit
elif [ "$status" -eq 0 ]; then
  echo "GATE: no STAGE=$stage EXIT line recorded - no verdict" >&2
  status=1
fi
goonix_gate_exit "$status"
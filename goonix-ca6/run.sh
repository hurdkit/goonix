#!/usr/bin/env bash
# goonix: CA-6 step 4 boot gate — the adopted small system booting in the
# private namespace.  Reuses the hello probe's namespace store (already has
# the substituted closure), starts the implementation daemon, and runs the
# marionette boot fixture under the 'adopted policy.  Host untouched.
set -euo pipefail
IMPL=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
HERE="$IMPL/goonix-ca6"
cd "$IMPL"

# goonix: a gate must run on a COMPILED tree.  The runner starts guile with
# --no-auto-compile, so an unbuilt tree is interpreted, which is a different
# load path and can fail on upstream macro hygiene (jq/oniguruma, DECISIONS 37).
# Refuse before anything is wiped or any daemon starts.
source "$HERE/gate-lib.sh"
goonix_gate_require_compiled "$IMPL" || exit 1

if ! unshare --user --map-root-user --mount true 2>/dev/null; then
  printf 'SKIP: user/mount namespaces are unavailable\n'
  exit 77
fi

scratch=${GOONIX_CA6_SCRATCH:-$HERE/work}
# GOONIX_CA6_FRESH=1: make this the COUNTED run (reviewer, 2026-11-22).
# A gate counts only when the job wipes its own test store and restores the
# download seed right before the run.  Runs 11-13 resumed the store the hello
# probe seeded, so a boot from them proves the chain works but is not the CA-6
# gate result.  With this option the same script does the counted run.
#
# The wipe happens HERE, before the namespace starts, so nothing is bound over
# /gnu/store yet and no daemon holds the database.  The seed is restored by
# running the hello probe, which substitutes hello's closure from bordeaux into
# this same scratch tree - the download seed the earlier runs started from.
if [ "${GOONIX_CA6_FRESH:-0}" = 1 ]; then
  echo "FRESH: wiping $scratch/store and $scratch/var, then restoring the seed"
  # Store items are mode 555 (read-only, as the daemon leaves them), so a plain
  # `rm -rf' cannot unlink their children and fails with "Permission denied"
  # even though we own them (measured, counted run 15).  Make the tree writable
  # first.  This touches only our own scratch tree, never the host store.
  chmod -R u+w "$scratch/store" "$scratch/var" "$scratch/log" 2>/dev/null || true
  rm -rf "$scratch/store" "$scratch/var" "$scratch/log"
  mkdir -p "$scratch/store" "$scratch/var" "$scratch/log"
  GOONIX_CA6_SCRATCH="$scratch" bash "$HERE/seed.sh" \
    > "$scratch/fresh-seed.log" 2>&1 || {
      echo "FRESH: seed restore FAILED; see $scratch/fresh-seed.log" >&2
      exit 1; }
  echo "FRESH: seed restored, store items: $(ls "$scratch/store" | wc -l)"
fi

mkdir -p "$scratch/store" "$scratch/var" "$scratch/etc" "$scratch/log"
chmod 700 "$scratch/etc"
{
  printf '(acl (entry '
  cat etc/substitutes/bordeaux.guix.gnu.org.pub
  printf ' (tag (guix import))))\n'
} > "$scratch/etc/acl"

# The daemon signs its build records (CA-5) with a secret key in its
# configuration directory and errors out if the file is missing or its
# permissions are wrong (checkSecrecy, nix/libstore/local-store.cc:1165).
# Without it the FIRST content-addressed build fails with "getting status of
# .../signing-key.sec: No such file or directory".  Use the repository's TEST
# keys, exactly as test-env and the CA-8 runner do, never the host's
# /etc/guix key.  Remove first: the installed key is mode 400, so a plain cp
# over it fails with "Permission denied" on a rerun.
rm -f "$scratch/etc/signing-key.sec" "$scratch/etc/signing-key.pub"
cp "$IMPL/tests/keys/openpgp/signing-key.sec" \
   "$IMPL/tests/keys/openpgp/signing-key.pub" \
   "$scratch/etc/"
chmod 400 "$scratch/etc/signing-key.sec"

# Build users for the namespace (reviewer, point 2).  Without them builtin
# builders run as namespace root and cannot chown to a build user: gate run
# 10 died in bootstrap-binaries-0 with
#   tar: ./bin/awk: Cannot change ownership to uid 1003, gid 30000:
#        Invalid argument
# and ~45 "1 dependencies couldn't be built" lines cascading from it.
#
# PORTABLE (reviewer, 2026-11-22): the ids and the subordinate ranges are read
# from the host at run time, not hardcoded for this NixOS laptop.  On the
# laptop the user is wrath (uid 1000, gid 100) with subuid/subgid 100000:65536
# and setuid wrappers in /run/wrappers/bin; on zergling2 it is hurdkit
# (uid 1003, gid 1003) on Ubuntu 24.04 WSL, subuid 231072:65536 AND 100000:65536
# but subgid ONLY 231072:65536, with newuidmap/newgidmap in /usr/bin.  Taking
# the first entry of each file handles both.
host_uid=$(id -u)
host_gid=$(id -g)
host_user=$(id -un)
# First subordinate range for this user in each file.
sub_uid=$(awk -F: -v u="$host_user" '$1==u {print $2; exit}' /etc/subuid)
sub_uid_count=$(awk -F: -v u="$host_user" '$1==u {print $3; exit}' /etc/subuid)
sub_gid=$(awk -F: -v u="$host_user" '$1==u {print $2; exit}' /etc/subgid)
sub_gid_count=$(awk -F: -v u="$host_user" '$1==u {print $3; exit}' /etc/subgid)
: "${sub_uid:?no /etc/subuid entry for $host_user}"
: "${sub_gid:?no /etc/subgid entry for $host_user}"
# newuidmap/newgidmap must be the SETUID ones.  Prefer /run/wrappers/bin when
# it exists (NixOS puts the setuid wrappers there, ahead of the store binary
# that has no setuid bit); otherwise take whatever is on PATH (Ubuntu's
# /usr/bin/newuidmap is setuid).
if [ -x /run/wrappers/bin/newuidmap ]; then
  export PATH=/run/wrappers/bin:$PATH
fi
command -v newuidmap >/dev/null || { echo 'newuidmap not on PATH' >&2; exit 1; }
command -v newgidmap >/dev/null || { echo 'newgidmap not on PATH' >&2; exit 1; }
echo "MAP: uid=$host_uid gid=$host_gid subuid=$sub_uid:$sub_uid_count subgid=$sub_gid:$sub_gid_count newuidmap=$(command -v newuidmap)"
# Namespace UID 0 -> the invoking host uid; UIDs 1..count -> the subordinate
# range.  Same for groups, from /etc/subgid (which may differ from subuid).
map_args=(--map-users=0:"$host_uid":1
          --map-users=1:"$sub_uid":"$sub_uid_count"
          --map-groups=0:"$host_gid":1
          --map-groups=1:"$sub_gid":"$sub_gid_count")

# passwd/group with a guixbuild group and ten build users at namespace IDs
# inside the subordinate range (UID 1..10, GID 1).  Their home is a directory
# in our own scratch tree, not /var/empty: on Ubuntu /var is root-owned and
# cannot be written even as namespace root (job ca6-z2-counted2).
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
  printf 'users:x:%s:\n' "$host_gid"
  printf 'guixbuild:x:1:'
  for i in $(seq 0 9); do
    printf 'guixbuilder%d' "$i"
    [ "$i" -lt 9 ] && printf ','
  done
  printf '\nnogroup:x:65534:\n'
} > "$scratch/etc/group.ns"

# A stale BOOT_EXIT from an earlier run reads as a pass.  Start clean so the
# result file only ever holds this run's outcome.
rm -f "$scratch/policy-boot-result"

# CPU budget (lanes USAGE.md): a command that starts a Guix build daemon must
# give it an explicit --cores and --max-jobs within the job's budget.
# guix-daemon does NOT read NIX_CONFIG (verified: no reference in nix/), and its
# defaults are max-jobs UNLIMITED and cores AUTO-DETECTED, so on zergling2 it
# would see 24 host cores under a 4-core quota and thrash.  z2run exports
# Z2_JOB_CORES; GOONIX_GATE_JOBS is this gate's own cap.
daemon_cores=${Z2_JOB_CORES:-${GOONIX_GATE_JOBS:-4}}
daemon_jobs=${GOONIX_DAEMON_MAX_JOBS:-1}
case "$daemon_cores" in ''|*[!0-9]*) echo "bad core count: $daemon_cores" >&2; exit 1;; esac
[ "$daemon_cores" -ge 1 ] || { echo 'core count must be >= 1' >&2; exit 1; }
echo "DAEMON_BUDGET cores=$daemon_cores max-jobs=$daemon_jobs"

cat > "$scratch/policy-boot-part.sh" <<EOF
set -euo pipefail
# Job isolation check, BEFORE any mount and before the daemon starts.  The
# runner enters a private PID namespace after installing the ID maps, so this
# script must be PID 1 of its own namespace.  Without it, the daemon's
# build-user cleanup kill(-1, SIGKILL) reaches other jobs' builders on the host
# (goonix DECISIONS 30).  Refuse rather than run unisolated: a green gate that
# could kill a neighbour is not a pass.  Regression: with the runner's
# 'exec unshare --pid --fork --kill-child' reverted to 'exec bash', this prints
# a PID other than 1 and exits non-zero (measured, goonix-ca6/pid-ns-check.sh).
echo "PID_NS_CHECK pid=\$\$ ns=\$(readlink /proc/self/ns/pid)"
if [ "\$\$" != 1 ]; then
  echo "REFUSING: not PID 1 of a private PID namespace (pid=\$\$);" \\
       "the runner must exec unshare --pid --fork --kill-child after the maps" >&2
  exit 1
fi
mount --bind '$scratch/store' /gnu/store
mount --bind '$scratch/var' /var/guix
# Build users, and hide the host's nscd: glibc answers getgrnam/getpwnam from
# /var/run/nscd/socket, which a mount namespace still reaches, so without
# this the bind-mounted passwd/group are ignored and the daemon would see
# the HOST's guixbuild gid (measured by the CA-8 runner).
mount --bind '$scratch/etc/passwd.ns' /etc/passwd
mount --bind '$scratch/etc/group.ns' /etc/group
# Mask nscd only when the host has it.  NixOS runs nscd, so the laptop needs
# this; Ubuntu 24.04 on zergling2 has no /run/nscd and the mount fails with
# "mount point does not exist", which under set -e aborted the whole gate
# before the daemon started (measured, job ca6-z2-counted1).  Create the
# directory when absent so the mask still applies if nscd appears later.
if [ -d /run/nscd ] || mkdir -p /run/nscd 2>/dev/null; then
  mount -t tmpfs tmpfs /run/nscd 2>/dev/null || true
fi
# /var/empty is the build users' home in the passwd entries.  On NixOS it
# exists; on Ubuntu 24.04 (zergling2) /var is real and root-owned, so
# 'mkdir -p /var/empty' fails with "Permission denied" even as namespace root
# and aborted the gate (measured, job ca6-z2-counted2).  Nothing needs the
# literal path, so the accounts' home is a directory in our own scratch tree
# (see passwd.ns above); create /var/empty too when permitted, for parity.
mkdir -p /var/empty 2>/dev/null || true
# 'nix develop' sets TMPDIR to its own /tmp/nix-shell.XXXX, mode 0700 and
# owned by namespace root, so a build USER cannot traverse it.  Bind a
# private world-traversable /tmp; the host's /tmp is untouched.
mount -t tmpfs -o mode=1777 tmpfs /tmp
export TMPDIR=/tmp
export NIX_STORE_DIR=/gnu/store
export GUIX_STATE_DIRECTORY='$scratch/var'
export GUIX_DATABASE_DIRECTORY='$scratch/var/db'
export GUIX_CONFIGURATION_DIRECTORY='$scratch/etc'
export GUIX_LOG_DIRECTORY='$scratch/log'
export GUIX_DAEMON_SOCKET='$scratch/socket'
export GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES=no
# Download cache (reviewer, 2026-11-22): the goonix download-cache hook
# (guix/download-cache.scm, 5b69dcb1f9c) reads GOONIX_DOWNLOAD_CACHE.  The
# cache is reachable at the same address from the laptop and from inside
# zergling2's WSL (a WSL redirect plus a Windows firewall rule).
export GOONIX_DOWNLOAD_CACHE='${GOONIX_DOWNLOAD_CACHE:-http://10.0.30.4:8480}'
cd '$IMPL'
./pre-inst-env ./guix-daemon --disable-chroot \\
  --build-users-group=guixbuild \\
  --cores=$daemon_cores --max-jobs=$daemon_jobs \\
  --listen='$scratch/socket' \\
  --substitute-urls='http://10.0.30.4:8480/substitutes/bordeaux https://bordeaux.guix.gnu.org' \\
  >'$scratch/policy-boot-daemon.log' 2>&1 &
daemon_pid=\$!
for i in \$(seq 1 100); do test -S '$scratch/socket' && break; sleep .1; done

# Live measures, written as the run goes and on ANY exit (reviewer,
# 2026-11-22).  Two earlier runs were cut off by an outer 'timeout', which
# killed the job before its summary lines ran, so the evidence had to be
# reconstructed from the raw log.  This file survives that: it is refreshed
# every 30 s by a background watcher and once more from the EXIT trap.
measures='$scratch/policy-boot-measures'
write_measures() {
  {
    echo "WHEN=\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "REFUSALS=\$(grep -c 'input-addressed derivation depends on' '$scratch/policy-boot.err' 2>/dev/null; true)"
    echo "CHOWN_ERRORS=\$(grep -c 'Cannot change ownership' '$scratch/policy-boot.err' 2>/dev/null; true)"
    echo "BUILD_EVENTS=\$(grep -c 'building path' '$scratch/policy-boot.err' 2>/dev/null; true)"
    echo "LAST_DERIVATION=\$(grep 'building path' '$scratch/policy-boot.err' 2>/dev/null | tail -1)"
    echo "ERR_LINES=\$(wc -l < '$scratch/policy-boot.err' 2>/dev/null || echo 0)"
    echo "BOOT_EXIT=\$(cat '$scratch/policy-boot-result' 2>/dev/null | tail -1)"
  } > "\$measures.tmp" 2>/dev/null
  mv -f "\$measures.tmp" "\$measures" 2>/dev/null || true
}
( while true; do sleep 30; write_measures; done ) &
watcher_pid=\$!
trap 'write_measures; kill "\$watcher_pid" "\$daemon_pid" 2>/dev/null || true' EXIT TERM INT HUP

./pre-inst-env guile --no-auto-compile "${GOONIX_CA6_SCRIPT:-$HERE/boot.scm}" \\
  >'$scratch/policy-boot.out' 2>'$scratch/policy-boot.err' && boot_exit=0 || boot_exit=\$?
echo "BOOT_EXIT=\$boot_exit" >> '$scratch/policy-boot-result'
write_measures
EOF

# Start the namespace, install the ID maps EXPLICITLY with
# newuidmap/newgidmap, then release the child.
#
# Measured on both hosts (goonix-ca6/z2-map-diag.sh, job ca6-z2-mapdiag):
#   laptop util-linux 2.42.3: '--map-users=0:UID:1 --map-users=1:SUB:N' works.
#   zergling2 util-linux 2.39.3: the SAME command writes only the subordinate
#   range - uid_map ends up "1 231072 65536" with NO 0->1003 line, so inside
#   the namespace 'id -u' is 65534 (nobody) and chown to a build user fails
#   with "Operation not permitted".  Reversing the option order loses the
#   subordinate range instead; comma-separated ranges are rejected outright.
# Explicit newuidmap on the parked child writes BOTH ranges on both hosts.
#
# The child parks until the maps are in place: it announces its PID, then
# waits for the go-ahead file.  Without that handshake the part script would
# start mounting and running the daemon as an unmapped uid.
rm -f "$scratch/ns-go" "$scratch/ns-pid"
unshare --user --mount bash -c '
  echo "$$" > "$1"
  for i in $(seq 1 600); do [ -e "$2" ] && break; sleep .1; done
  [ -e "$2" ] || { echo "no maps go-ahead" >&2; exit 1; }
  # Job isolation (reviewer, 2026-11-23; lanes DECISIONS "Job isolation goes
  # into the committed runners").  A private PID namespace INSIDE the mapping
  # boundary that newuidmap/newgidmap just installed: the daemon build-user
  # cleanup does kill(-1, SIGKILL), which without this reaches every process
  # of that leased uid on the HOST - it killed another job'"'"'s builders
  # (goonix DECISIONS 30).  --fork is required by --pid; --kill-child ties the
  # part script'"'"'s lifetime to this child.  It must come AFTER the maps: a
  # PID namespace created outside/above the user namespace breaks the
  # newuidmap handshake outright (measured: "Target process is owned by a
  # different user").  The part script refuses to start the daemon unless it
  # is PID 1 in its own namespace, so this line cannot silently regress.
  exec unshare --pid --fork --kill-child -- bash "$3"
' _ "$scratch/ns-pid" "$scratch/ns-go" "$scratch/policy-boot-part.sh" \
  > "$scratch/policy-boot-run.log" 2>&1 &
ns_job=$!
ns_pid=''
for i in $(seq 1 300); do
  # || true: under `set -o pipefail` a missing pid file makes cat fail, the
  # assignment inherits that status, and `set -e` aborts the whole run on the
  # FIRST poll iteration (measured, counted run 16: the trace stops right here
  # with ns_pid empty).  It is a race - z2 won it, the laptop lost it.
  ns_pid=$(cat "$scratch/ns-pid" 2>/dev/null | head -1 || true)
  [ -n "$ns_pid" ] && break
  sleep .1
done
if [ -z "$ns_pid" ]; then
  echo 'namespace child did not start; see policy-boot-run.log' >&2
  cat "$scratch/policy-boot-run.log" >&2
  exit 1
fi
newuidmap "$ns_pid" 0 "$host_uid" 1 1 "$sub_uid" "$sub_uid_count"
newgidmap "$ns_pid" 0 "$host_gid" 1 1 "$sub_gid" "$sub_gid_count"
echo "MAPS INSTALLED for pid $ns_pid"
: > "$scratch/ns-go"
wait "$ns_job" || true

echo '=== policy-boot-result ==='
cat "$scratch/policy-boot-result" 2>/dev/null || echo 'no result'
echo '=== policy-boot.out ==='
cat "$scratch/policy-boot.out" 2>/dev/null | tail -25
echo '=== policy-boot.err tail ==='
tail -20 "$scratch/policy-boot.err" 2>/dev/null || true

# goonix: exit with the GATE'S verdict, not with the status of the last `tail`.
# Counted run 18c recorded BOOT_EXIT=1 and still returned 0 to the z2run unit,
# because this script ended with a diagnostic tail; a reader could mistake that
# for a pass (reviewer, DECISIONS 37).  The part script appends
# "BOOT_EXIT=<status>" to policy-boot-result; take the LAST such line.  No
# result line at all means the gate never produced a verdict, which is a
# failure, not a pass.
boot_exit=$(grep -o '^BOOT_EXIT=[0-9]*' "$scratch/policy-boot-result" 2>/dev/null \
            | tail -1 | cut -d= -f2 || true)
if [ -z "$boot_exit" ]; then
  echo 'GATE: no BOOT_EXIT recorded - the gate produced no verdict' >&2
  boot_exit=1
fi
goonix_gate_exit "$boot_exit"
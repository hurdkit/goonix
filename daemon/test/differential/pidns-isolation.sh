#!/usr/bin/env bash
# Regression: the namespace runners refuse to start a daemon outside a private
# PID namespace, and each committed runner really enters one.
#
# WHY: a daemon kills every process of a build user before reusing that user for
# a build.  The build-user uids come from the HOST range, so two jobs that each
# run a namespace daemon with --build-users-group=guixbuild share them: one
# job's kill(-1) as a build user reaches the other job's builders and its daemon
# dies mid-reply (the counted CA gate's rc=141/SIGPIPE while another session's
# CA-8 job ran).  A per-job PID namespace confines the kill.
#
# The runner-side fix is one visible line, after the uid/gid maps are installed:
#   exec unshare --pid --fork --kill-child -- bash <part-script>
# and the part script calls pidns-guard.sh before it starts the daemon.
#
# Usage: pidns-isolation.sh
set -uo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
here="$root/daemon/test/differential"
guard="$here/pidns-guard.sh"
fails=0

check() { # LABEL EXPECTED_RC ACTUAL_RC
  if test "$2" = "$3"; then
    echo "ok   $1"
  else
    echo "FAIL $1 (expected rc=$2, got $3)"
    fails=$((fails + 1))
  fi
}

# 1. FAIL-BEFORE: the guard outside a PID namespace must refuse.  This is the
#    state every runner was in before the unshare --pid line was added.
#    Sourced in a SUBSHELL: the guard exits its shell on refusal, exactly as it
#    exits the part script.
( . "$guard" regression-outside ) > /dev/null 2>&1
check "the guard refuses outside a private PID namespace" 1 $?

# 2. PASS-AFTER: inside unshare --pid --fork it must accept, as PID 1.
export PATH=/run/wrappers/bin:$PATH
out=$(unshare --user --map-root-user --fork --pid -- \
  bash -c '. "$1" regression-inside' guard "$guard" 2>&1)
check "the guard accepts inside a private PID namespace" 0 $?
case "$out" in
  *PIDNS_GUARD_OK*pid=1*) echo "ok   the guard reports pid=1 and its namespace";;
  *) echo "FAIL the guard did not report pid=1 and its namespace: $out"; fails=$((fails + 1));;
esac

# 3. The namespace must be a NEW one, not the host's: the guard compares inodes.
self_ns=$(unshare --user --map-root-user --fork --pid -- \
  bash -c 'readlink /proc/self/ns/pid' 2>/dev/null)
host_ns=$(readlink /proc/1/ns/pid 2>/dev/null)
if test -n "$self_ns" && test "$self_ns" != "$host_ns"; then
  echo "ok   the entered namespace differs from the host's"
else
  echo "FAIL the entered namespace is the host's ($self_ns)"
  fails=$((fails + 1))
fi

# 4. Every committed runner that starts a namespace daemon carries the line,
#    and its part script calls the guard BEFORE the daemon starts.
for pair in \
  "ca-counted-gate.sh ca-counted-gate-part.sh" \
  "root-ci.sh root-ci-part.sh" \
  "ca-deep-scan-installed.sh ca-deep-scan-installed-part.sh"
do
  set -- $pair
  runner="$here/$1"; part="$here/$2"
  if grep -qE 'exec unshare --pid --fork --kill-child -- (bash|"\$part_bash")' "$runner"; then
    echo "ok   $1 enters a private PID namespace"
  else
    echo "FAIL $1 has no exec unshare --pid --fork --kill-child line"
    fails=$((fails + 1))
  fi
  guard_line=$(grep -n 'pidns-guard.sh' "$part" | head -1 | cut -d: -f1)
  daemon_line=$(grep -n 'build-users-group' "$part" | head -1 | cut -d: -f1)
  if test -n "$guard_line" && test -n "$daemon_line" && test "$guard_line" -lt "$daemon_line"; then
    echo "ok   $2 checks the namespace before starting the daemon"
  else
    echo "FAIL $2 does not guard before the daemon (guard=$guard_line daemon=$daemon_line)"
    fails=$((fails + 1))
  fi
done

# 5. The part script really refuses when it is NOT PID 1: run it directly with
#    arguments that would otherwise reach the daemon.  The guard is SOURCED, so
#    its own exit 1 ends the part script before any daemon starts.
bash "$here/ca-counted-gate-part.sh" /nonexistent-ns "$root" /nonexistent-daemon \
  regression /nonexistent-guile "" "" "" "" "" "" "ca" > /dev/null 2>&1
check "the counted gate part refuses to start a daemon outside a PID namespace" 1 $?

# 6. The scratch-/bin hazard (found on WSL by the lanes session): worktree mode
#    bind-mounts a scratch /bin over /bin, so the runner must exec an ABSOLUTE
#    bash that survives the mount, and setup must provide bash in that scratch.
if test -f "$here/root-ci-setup.sh"; then
  if grep -q 'work/bin/bash' "$here/root-ci-setup.sh"; then
    echo "ok   root-ci-setup provides bash in the scratch /bin"
  else
    echo "FAIL root-ci-setup does not put bash in the scratch /bin"
    fails=$((fails + 1))
  fi
fi
for pair in "root-ci.sh" "stress-gate.sh"; do
  runner="$here/$pair"
  test -f "$runner" || continue
  if grep -qE 'kill-child -- bash ' "$runner"; then
    echo "FAIL $pair execs a bare bash, hidden by the scratch /bin mount"
    fails=$((fails + 1))
  else
    echo "ok   $pair execs an absolute bash"
  fi
done

if test "$fails" -eq 0; then
  echo "REGRESSION PASS: namespace runners are job-isolated"
  exit 0
fi
echo "REGRESSION FAIL: $fails check(s) failed"
exit 1
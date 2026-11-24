#!/usr/bin/env bash
# Refuse to start a namespace daemon outside a private PID namespace.
#
# A daemon kills every process of a build user before reusing that user for a
# build (C++ killUser, HS the same).  The build users come from the HOST
# /etc/passwd range, so two jobs that each run a namespace daemon with
# --build-users-group=guixbuild share those uids: one job's kill(-1) as a build
# user reaches the other job's builders and its daemon dies mid-reply (the
# counted gate's rc=141/SIGPIPE).  A per-job PID namespace confines that kill to
# the job's own processes.
#
# Each runner enters it with
#   exec unshare --pid --fork --kill-child -- bash <part-script>
# AFTER the uid/gid maps are installed (the newuidmap handshake needs the
# original user namespace; --kill-child also reaps the job's strays on exit).
# This script is the check that the runner really did so.
#
# Usage: . pidns-guard.sh LABEL      (SOURCE it, do not run it as a child)
# Sourcing matters: the check is on the part script's own $$, which must be 1.
# Run as a child (`bash pidns-guard.sh`) the guard would test its OWN pid, which
# is 2 even when the part script is correctly PID 1.
# Prints the namespace and exits non-zero unless this process is PID 1 of a
# PID namespace that is not the host's.
set -uo pipefail
label=${1:-job}

if test "$$" != 1; then
  echo "PIDNS_GUARD_FAIL[$label]: pid=$$ is not 1 - the runner did not enter a private PID namespace" >&2
  echo "  the runner must exec: unshare --pid --fork --kill-child -- bash <part>" >&2
  exit 1
fi

# PID 1 alone is not proof: compare the namespace inode with the host's, which
# /proc/1/ns/pid still names because procfs was mounted before the unshare.
self_ns=$(readlink /proc/self/ns/pid 2>/dev/null)
host_ns=$(readlink /proc/1/ns/pid 2>/dev/null)
if test -n "$self_ns" && test -n "$host_ns" && test "$self_ns" = "$host_ns"; then
  echo "PIDNS_GUARD_FAIL[$label]: pid namespace $self_ns is the host's" >&2
  exit 1
fi

echo "PIDNS_GUARD_OK[$label]: pid=$$ ns=$self_ns"
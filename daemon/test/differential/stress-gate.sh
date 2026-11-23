#!/usr/bin/env bash
# goonix: one-process-many-clients concurrency stress gate (reviewer, pre-host-switch).
# Runs root-ci's setup (namespace root, build users, chroot, the installed package
# daemon) and then stress-client.scm: several build clients + a noisy-log/silent
# substitute client + a GC client + a roots/temp-roots client + a watchdog, all at
# once against ONE daemon.  Runs the client TWICE: once with the daemon's normal RTS
# options and once with -A1m (small nursery forces GC, exposing capability freezes).
#
# This is a STRESS gate, not a quick regression: it builds derivations in the chroot
# and runs a ~6s silent helper, so it takes a few minutes.  It is deliberately NOT
# wired into root-ci.sh's fast path; run it on its own before the host switch.
#
# Usage: stress-gate.sh DAEMON [LABEL]
#   ROOT_CI_MODE=installed (default) | worktree   (as root-ci.sh)
#   WATCHDOG_BOUND=3  STRESS_BUILDS=3  SILENT_SECONDS=6  (passed to the client/helper)
set -uo pipefail
daemon=${1:?usage: stress-gate.sh DAEMON [LABEL]}
label=${2:-$(basename "$daemon")}
mode=${ROOT_CI_MODE:-installed}
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
here="$root/daemon/test/differential"
work=/tmp/pr6-root-ci/$label
uid=$(id -u)
gid=$(id -g)

# Subordinate ID ranges: read the invoking user's FIRST range from /etc/subuid and
# /etc/subgid instead of hard-coding the laptop's 100000, so the gate runs on any
# host (laptop wrath:100000:65536, zergling2 hurdkit:231072:65536).  Overridable.
uname=$(id -un)
subuid_line=$(awk -F: -v u="$uname" -v i="$uid" '($1==u||$1==i){print $2":"$3; exit}' /etc/subuid 2>/dev/null)
subgid_line=$(awk -F: -v u="$uname" -v i="$gid" '($1==u||$1==i){print $2":"$3; exit}' /etc/subgid 2>/dev/null)
subuid_start=${STRESS_SUBUID_START:-${subuid_line%%:*}}
subuid_count=${STRESS_SUBUID_COUNT:-${subuid_line##*:}}
subgid_start=${STRESS_SUBGID_START:-${subgid_line%%:*}}
subgid_count=${STRESS_SUBGID_COUNT:-${subgid_line##*:}}
: "${subuid_start:?no /etc/subuid range for $uname}" "${subuid_count:?}"
: "${subgid_start:?no /etc/subgid range for $uname}" "${subgid_count:?}"
echo "subuid=$subuid_start:$subuid_count subgid=$subgid_start:$subgid_count"

bash "$here/root-ci-setup.sh" "$daemon" "$label" || exit 1
daemon=$(readlink -f "$daemon")

# Payload hash + dev-shell guile load paths, as root-ci.sh.
devinfo=$(cd "$root" && nix develop .#default -c bash -c 'guile --no-auto-compile -L . -c "(use-modules (guix hash) (guix base32) (gcrypt hash) (rnrs io ports)) (display (bytevector->nix-base32-string (sha256 (call-with-input-file \"'"$work"'/payload.txt\" get-bytevector-all)))) (newline)"; echo "GLP=$GUILE_LOAD_PATH"; echo "GLCP=$GUILE_LOAD_COMPILED_PATH"')
payload_hash=$(echo "$devinfo" | sed -n 1p)
dev_glp=$(echo "$devinfo" | grep '^GLP=' | sed 's/^GLP=//')
dev_glcp=$(echo "$devinfo" | grep '^GLCP=' | sed 's/^GLCP=//')
echo "payload_hash=$payload_hash mode=$mode"

export PATH=/run/wrappers/bin:$PATH
timeout 900 unshare --user \
  --map-users=0:"$uid":1 --map-users=1:"$subuid_start":"$subuid_count" \
  --map-groups=0:"$gid":1 --map-groups=1:"$subgid_start":"$subgid_count" \
  --mount -- bash -c '
    set -uo pipefail
    work="'"$work"'"; root="'"$root"'"; daemon="'"$daemon"'"; mode="'"$mode"'"
    payload_hash="'"$payload_hash"'"; dev_glp="'"$dev_glp"'"; dev_glcp="'"$dev_glcp"'"
    here="$root/daemon/test/differential"
    for port in 18080 19418; do
      if ss -ltn 2>/dev/null | grep -qE "[:.]$port[[:space:]]"; then
        echo "port $port is in use; stop the listener before running the stress gate" >&2
        exit 3
      fi
    done
    dpid=; http_pid=
    cleanup() {
      trap - EXIT INT TERM
      kill $dpid $http_pid 2>/dev/null
      wait $dpid $http_pid 2>/dev/null
    }
    trap cleanup EXIT
    trap "exit 130" INT
    trap "exit 143" TERM
    mount --bind "$work/etc/passwd" /etc/passwd
    mount --bind "$work/etc/group" /etc/group
    mount --bind "$work/etc/nsswitch.conf" /etc/nsswitch.conf
    mount --bind /dev/null /var/run/nscd/socket 2>/dev/null
    mount --bind "$work/gnu-store" /gnu/store
    mount --bind "$work/var-guix" /var/guix
    mount --bind "$work/log-guix" /var/log/guix
    if test "$mode" = worktree; then
      mount --bind "$HOME" "$HOME"; chmod 755 "$HOME"
      mount --bind "$work/bin" /bin
    fi
    # Job isolation: the uid/gid maps are installed, so enter a PRIVATE PID
    # namespace before the daemon starts.  A daemon kills every process of a
    # build user before a build and those uids come from the host range, so
    # without this the kill(-1) of one job reaches the builders of another.
    exec unshare --pid --fork --kill-child -- bash "$0" "$@"
  ' "$here/stress-gate-part.sh" "$work" "$root" "$daemon" "$mode" \
    "$payload_hash" "$dev_glp" "$dev_glcp"
rc=$?
echo "stress-gate[$label] rc=$rc"
exit $rc
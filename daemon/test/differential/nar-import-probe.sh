#!/usr/bin/env bash
# Isolate the stress-gate build hang: the hanging clients (build/roots/watchdog) all
# call add-to-store (NAR import via readSocket); the passing ones (substitute/gc) do
# not.  Run a minimal add-to-store probe against a worktree daemon in the root-ci
# namespace to see whether add-to-store hangs with the IO-manager socket fix.
set -uo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
here="$root/daemon/test/differential"
work=/tmp/pr6-root-ci/narprobe
uid=$(id -u); gid=$(id -g)
bash "$here/root-ci-setup.sh" "$root/guix-daemon" narprobe || exit 1
devinfo=$(cd "$root" && nix develop .#default -c bash -c 'echo "GLP=$GUILE_LOAD_PATH"; echo "GLCP=$GUILE_LOAD_COMPILED_PATH"')
dev_glp=$(echo "$devinfo" | grep '^GLP=' | sed 's/^GLP=//')
dev_glcp=$(echo "$devinfo" | grep '^GLCP=' | sed 's/^GLCP=//')
timeout_abs=$(command -v timeout)
# Wrap the noisy helper with an absolute bash + dev PATH (daemon spawns it with
# PATH=/nonexistent), as root-ci-substitute.sh does.  Done OUTSIDE the namespace
# block so the single quotes do not conflict with the outer bash -c quoting.
bash_abs=$(command -v bash); dev_path="$PATH"
helper="$work/noisy-helper.wrapper"
{ printf '#!%s\n' "$bash_abs"; printf 'export PATH=%s\n' "$dev_path";
  cat "$here/stress-noisy-helper.sh"; } > "$helper"
chmod +x "$helper"
export PATH=/run/wrappers/bin:$PATH
timeout 150 unshare --user \
  --map-users=0:"$uid":1 --map-users=1:100000:65536 \
  --map-groups=0:"$gid":1 --map-groups=1:100000:65536 \
  --mount -- bash -c '
    set -uo pipefail
    work="'"$work"'"; root="'"$root"'"; dev_glp="'"$dev_glp"'"; dev_glcp="'"$dev_glcp"'"; timeout_abs="'"$timeout_abs"'"; helper="'"$helper"'"
    mount --bind "$work/etc/passwd" /etc/passwd
    mount --bind "$work/etc/group" /etc/group
    mount --bind "$work/etc/nsswitch.conf" /etc/nsswitch.conf
    mount --bind "$work/gnu-store" /gnu/store
    mount --bind "$work/var-guix" /var/guix
    mount --bind "$work/log-guix" /var/log/guix
    mount --bind "$HOME" "$HOME"; chmod 755 "$HOME"
    mount --bind "$work/bin" /bin
    env -i TMPDIR="$work/build" LC_ALL=C.UTF-8 PATH=/nonexistent GUIX="$helper" \
      GUILE_LOAD_PATH="$root:$dev_glp" GUIX_UNINSTALLED=1 GUIX_SANDBOX="$root/guix-sandbox" \
      "$root/guix-daemon" --build-users-group=guixbuild --max-jobs=2 --substitute-urls="" \
      --no-substitutes --no-offload > "$work/daemon.log" 2>&1 &
    dpid=$!
    for i in $(seq 1 200); do test -S /var/guix/daemon-socket/socket && break; sleep .05; done
    env -i LC_ALL=C.UTF-8 PATH=/nonexistent GUIX_DAEMON_SOCKET=/var/guix/daemon-socket/socket \
      GUILE_LOAD_PATH="$root:$dev_glp" GUILE_LOAD_COMPILED_PATH="$root:$dev_glcp" GUIX_UNINSTALLED=1 \
      "$timeout_abs" 60 "$root/guile" --no-auto-compile \
      "$root/daemon/test/differential/build-probe.scm" \
      /var/guix/daemon-socket/socket > "$work/build-probe.log" 2>&1
    echo BUILD_PROBE_RC=$?
    echo === build-probe log ===
    cat "$work/build-probe.log"
    echo === daemon log ===
    head -8 "$work/daemon.log"
    kill $dpid 2>/dev/null
  '
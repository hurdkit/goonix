#!/usr/bin/env bash
# goonix: the COUNTED HS-11 CA gate — the 16 CA suites through the INSTALLED
# daemon, as namespace root, with real build users and the chroot ON, bare
# environment (the root-ci.sh "installed" pattern).  NOT the build-tree gate
# (gate-file.sh / test-env), which runs the worktree daemon with --disable-chroot
# on z2 and does not count.
#
# Usage: ca-counted-gate.sh HS_PKG CXX_PKG WORK
#   HS_PKG   installed Haskell-daemon package (nix build ...#default out-link)
#   CXX_PKG  installed C++-daemon package (nix build ...#goonix-cxx-daemon)
#   WORK     scratch directory for the gate (created/wiped)
#
# For each daemon: root-ci-setup-style namespace (uid->0, subuid 100000:65536->
# 1:65536, bind-mounted scratch /gnu/store /var/guix /var/log/guix /etc/passwd
# /etc/group), the installed daemon as root with --build-users-group=guixbuild
# and env -i (only TMPDIR/LC_ALL/PATH=/nonexistent — no GUIX_*/GUILE_*, chroot ON,
# no --no-offload), seed the fresh store, then run each tests/ca*.scm through the
# installed package's guile + modules via build-aux/test-driver.scm, capturing
# .trs.  A common GOONIX_SCAN_REAL_STORE fixture makes ca-scan's real-store count
# host-independent.  Finally compare-trs.sh HS vs CXX by test name.
#
# CA_COUNTED_SUITES overrides the suite list (default: all 16).  A subset run is
# for diagnosing one suite; only the full 16-suite run counts as the gate.
set -uo pipefail
hs_pkg=${1:?usage: ca-counted-gate.sh HS_PKG CXX_PKG WORK}
cxx_pkg=${2:?}
work=${3:?}
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
here="$root/daemon/test/differential"
hs_daemon=$(readlink -f "$hs_pkg/bin/guix-daemon")
cxx_daemon=$(readlink -f "$cxx_pkg/bin/guix-daemon")
uid=$(id -u); gid=$(id -g)
mkdir -p "$work"
suites=${CA_COUNTED_SUITES:-"ca ca-adopt ca-build ca-compiler ca-existing-item ca-files ca-fixed-output ca-full ca-graft-identity ca-grafts ca-opaque ca-policy ca-references ca-rewrite ca-scan ca-sharing"}

# --- dev-shell guile + load paths (the client loads the INSTALLED package's
#     modules first, then the dev shell's guile-gcrypt/guile-git/etc.) ---
devinfo=$(cd "$root" && nix develop .#default -c bash -c '
  command -v guile; command -v sqlite3; command -v slirp4netns
  echo "GLP=$GUILE_LOAD_PATH"; echo "GLCP=$GUILE_LOAD_COMPILED_PATH"')
guile_bin=$(echo "$devinfo" | sed -n 1p)
sqlite3_bin=$(echo "$devinfo" | sed -n 2p)
slirp_bin=$(echo "$devinfo" | sed -n 3p)
dev_glp=$(echo "$devinfo" | grep '^GLP=' | sed 's/^GLP=//')
dev_glcp=$(echo "$devinfo" | grep '^GLCP=' | sed 's/^GLCP=//')
echo "guile=$guile_bin sqlite3=$sqlite3_bin slirp4netns=$slirp_bin"
echo "hs_daemon=$hs_daemon"
echo "cxx_daemon=$cxx_daemon"

# --- the common ca-scan real-store fixture (host-independent count) ---
fixture="$work/scan-real-store"
(cd "$root" && nix develop .#default -c bash daemon/test/scan-real-store-fixture.sh "$fixture") \
  > "$work/fixture.log" 2>&1
echo "FIXTURE_RC=$? $(tail -1 "$work/fixture.log")"

# --- per-daemon namespace setup (root-ci-setup.sh pattern) ---
setup_ns() {
  local label=$1 ns="$work/$label"
  rm -rf "$ns"; mkdir -p "$ns"/{gnu-store,var-guix,log-guix,etc,build,cache,substituter-data}
  mkdir -p "$ns/var-guix"/{db,gcroots,profiles,temproots,daemon-socket}
  {
    printf 'root:x:0:0:root:/root:/bin/sh\n'
    printf 'nobody:x:65534:65534:nobody:/var/empty:/bin/sh\n'
    printf 'guixbuilder01:x:30001:30000:Guix build user 1:/var/empty:/bin/sh\n'
    printf 'guixbuilder02:x:30002:30000:Guix build user 2:/var/empty:/bin/sh\n'
    printf 'guixbuilder03:x:30003:30000:Guix build user 3:/var/empty:/bin/sh\n'
  } > "$ns/etc/passwd"
  {
    printf 'root:x:0:\n'
    printf 'nogroup:x:65534:\n'
    printf 'guixbuild:x:30000:guixbuilder01,guixbuilder02,guixbuilder03\n'
  } > "$ns/etc/group"
  printf 'passwd: files\ngroup: files\nshadow: files\nhosts: files dns\n' > "$ns/etc/nsswitch.conf"
  "$sqlite3_bin" "$ns/var-guix/db/db.sqlite" < "$root/guix/store/schema.sql"
  printf 7 > "$ns/var-guix/db/schema"
  # The daemon signs CA build records with /etc/guix/signing-key.sec.  The host
  # key is root-owned 0600 and the namespace root maps to the caller (uid 1000),
  # which cannot read it.  Bind-mount a scratch /etc/guix holding the test key
  # (the established differential-test pattern: archive.sh / fresh-store.sh copy
  # tests/keys/openpgp/signing-key.sec, chmod 0400).  The key only signs records
  # within this fresh scratch store; it is not the host substitute key.
  mkdir -p "$ns/etc-guix"
  cp "$root/tests/keys/openpgp/signing-key.sec" "$ns/etc-guix/signing-key.sec"
  cp "$root/tests/keys/openpgp/signing-key.pub" "$ns/etc-guix/signing-key.pub"
  chmod 0400 "$ns/etc-guix/signing-key.sec"
  # The bootstrap binaries the CA suites add-to-store (gitignored in the tree,
  # present in the worktree).  search-bootstrap-binary maps x86_64->i686.
  mkdir -p "$ns/bootstrap"
  cp "$root/gnu/packages/bootstrap/i686-linux/bash" "$ns/bootstrap/bash" 2>/dev/null || true
  cp "$root/gnu/packages/bootstrap/i686-linux/mkdir" "$ns/bootstrap/mkdir" 2>/dev/null || true
}

# --- run one daemon's 16 suites inside its namespace ---
run_daemon() {
  local label=$1 daemon=$2 pkg=$3
  local ns="$work/$label"
  setup_ns "$label"
  local pkg_glp="$pkg/share/guile/site/3.0"
  local pkg_glcp="$pkg/lib/guile/3.0/site-ccache"
  export PATH=/run/wrappers/bin:$PATH
  timeout 2400 unshare --user \
    --map-users=0:"$uid":1 --map-users=1:100000:65536 \
    --map-groups=0:"$gid":1 --map-groups=1:100000:65536 \
    --mount -- bash -c '
      set -uo pipefail
      ns="'"$ns"'"; root="'"$root"'"; daemon="'"$daemon"'"; label="'"$label"'"
      guile_bin="'"$guile_bin"'"; dev_glp="'"$dev_glp"'"; dev_glcp="'"$dev_glcp"'"
      pkg_glp="'"$pkg_glp"'"; pkg_glcp="'"$pkg_glcp"'"; fixture="'"$fixture"'"
      slirp_bin="'"$slirp_bin"'"
      suites="'"$suites"'"
      mount --bind "$ns/etc/passwd" /etc/passwd
      mount --bind "$ns/etc/group" /etc/group
      mount --bind "$ns/etc/nsswitch.conf" /etc/nsswitch.conf
      mount --bind /dev/null /var/run/nscd/socket 2>/dev/null
      mount --bind "$ns/gnu-store" /gnu/store
      mount --bind "$ns/var-guix" /var/guix
      mount --bind "$ns/log-guix" /var/log/guix
      mount --bind "$ns/etc-guix" /etc/guix
      # Job isolation: the maps above are installed, so enter a PRIVATE PID
      # namespace before any daemon starts.  A daemon kills all of a build
      # users processes before a build, and the build-user uids come from the
      # host range, so without this one jobs kill(-1) reaches another jobs
      # builders.  --kill-child reaps this jobs strays when it exits.
      # Absolute bash: a scratch /bin bind-mounted over /bin hides /bin/bash on a
      # merged-usr host (WSL: the real one is /usr/bin/bash).  Prefer the absolute
      # path of the running shell when it is not under the hidden /bin.
      part_bash=$BASH
      case "$part_bash" in /bin/*) part_bash=$(command -v bash) ;; esac
      exec unshare --pid --fork --kill-child -- "$part_bash" "$0" "$@"
    ' "$here/ca-counted-gate-part.sh" "$ns" "$root" "$daemon" "$label" \
      "$guile_bin" "$dev_glp" "$dev_glcp" "$pkg_glp" "$pkg_glcp" "$fixture" \
      "$slirp_bin" "$suites"
  echo "RUN_${label}_RC=$?"
}

run_daemon HS "$hs_daemon" "$hs_pkg"
run_daemon CXX "$cxx_daemon" "$cxx_pkg"

echo "=== NAME-BY-NAME COMPARISON (CXX baseline vs HS) ==="
mkdir -p "$work/cxx-names" "$work/hs-names"
for name in $suites; do
  cp "$work/CXX/results/$name.trs" "$work/cxx-names/$name.trs" 2>/dev/null || true
  cp "$work/HS/results/$name.trs" "$work/hs-names/$name.trs" 2>/dev/null || true
done
bash "$root/daemon/test/compare-trs.sh" "$work/cxx-names" "$work/hs-names" > "$work/compare.log" 2>&1
echo "COMPARE_RC=$?"
grep -E 'CHANGED|MISSING|EXTRA' "$work/compare.log" || echo 'ALL NAMES IDENTICAL'
echo "=== counted gate done ==="
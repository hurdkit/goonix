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
suites="ca ca-adopt ca-build ca-compiler ca-existing-item ca-files ca-fixed-output ca-full ca-graft-identity ca-grafts ca-opaque ca-policy ca-references ca-rewrite ca-scan ca-sharing"

# --- dev-shell guile + load paths (the client loads the INSTALLED package's
#     modules first, then the dev shell's guile-gcrypt/guile-git/etc.) ---
devinfo=$(cd "$root" && nix develop .#default -c bash -c '
  command -v guile; command -v sqlite3
  echo "GLP=$GUILE_LOAD_PATH"; echo "GLCP=$GUILE_LOAD_COMPILED_PATH"')
guile_bin=$(echo "$devinfo" | sed -n 1p)
sqlite3_bin=$(echo "$devinfo" | sed -n 2p)
dev_glp=$(echo "$devinfo" | grep '^GLP=' | sed 's/^GLP=//')
dev_glcp=$(echo "$devinfo" | grep '^GLCP=' | sed 's/^GLCP=//')
echo "guile=$guile_bin sqlite3=$sqlite3_bin"
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
      suites="'"$suites"'"
      mount --bind "$ns/etc/passwd" /etc/passwd
      mount --bind "$ns/etc/group" /etc/group
      mount --bind "$ns/etc/nsswitch.conf" /etc/nsswitch.conf
      mount --bind /dev/null /var/run/nscd/socket 2>/dev/null
      mount --bind "$ns/gnu-store" /gnu/store
      mount --bind "$ns/var-guix" /var/guix
      mount --bind "$ns/log-guix" /var/log/guix
      # The installed daemon as namespace root: chroot ON (default), build users,
      # env -i (only TMPDIR/LC_ALL/PATH=/nonexistent).  No GUIX_*/GUILE_*, no
      # --no-offload: the package finds its own helpers and sandbox.
      env -i TMPDIR="$ns/build" LC_ALL=C.UTF-8 PATH=/nonexistent \
        "$daemon" --build-users-group=guixbuild --max-jobs=2 --substitute-urls="" \
        > "$ns/daemon.log" 2>&1 &
      dpid=$!
      for i in $(seq 1 200); do test -S /var/guix/daemon-socket/socket && break; sleep 0.1; done
      if ! test -S /var/guix/daemon-socket/socket; then
        echo "DAEMON DID NOT START ($label)"; head -20 "$ns/daemon.log"; kill $dpid 2>/dev/null; exit 2
      fi
      # Client environment: the WORKTREE first on the load path (exactly as
      # pre-inst-env: builddir:srcdir:$GUILE_LOAD_PATH), then the installed
      # package modules, then dev-shell deps.  Worktree-first is required so
      # gnu/packages/bootstrap.scm resolves from the worktree, where the
      # gitignored bootstrap binaries (bash/mkdir) live; the package ships no
      # bootstrap dir and is read-only, so search-bootstrap-binary would try to
      # write the built binary into the nix store and fail.  The daemon under
      # test is still the INSTALLED package; only the client modules load this
      # way.  NIX_STORE_DIR=/gnu/store matches the daemon; the socket is the
      # configure-time /var/guix/daemon-socket/socket.
      client_env() {
        env -i LC_ALL=C.UTF-8 PATH=/nonexistent HOME="$ns" \
          NIX_STORE_DIR=/gnu/store \
          GUIX_STATE_DIRECTORY=/var/guix \
          GUIX_DAEMON_SOCKET=/var/guix/daemon-socket/socket \
          GUIX_DATABASE_DIRECTORY=/var/guix/db \
          GUIX_LOG_DIRECTORY=/var/log/guix \
          GUIX_BINARY_SUBSTITUTE_URL="file://$ns/substituter-data" \
          GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES=yes \
          GOONIX_SCAN_REAL_STORE="$fixture" \
          GUILE_LOAD_PATH="$root:$pkg_glp:$dev_glp" \
          GUILE_LOAD_COMPILED_PATH="$root:$pkg_glcp:$dev_glcp" \
          GUILE_AUTO_COMPILE=0 \
          "$@"
      }
      # Seed the fresh store (bootstrap binaries + downloads).  The seed lives
      # at the caller absolute cache path (HOME inside the ns is the scratch).
      client_env "$guile_bin" --no-auto-compile \
        "$root/daemon/test/seed-restore.scm" "/home/wrath/.cache/goonix-test-seed" \
        > "$ns/seed.log" 2>&1
      echo "SEED_RC_${label}=$? $(tail -1 "$ns/seed.log")"
      mkdir -p "$ns/results"
      for name in $suites; do
        client_env "$guile_bin" --no-auto-compile -e main \
          "$root/build-aux/test-driver.scm" \
          --test-name="tests/$name" --log-file="$ns/results/$name.log" \
          --trs-file="$ns/results/$name.trs" --brief=yes --color-tests=no \
          -- "$root/tests/$name.scm" > "$ns/results/$name.out" 2>&1
        rc=$?
        pass=$(grep -c ":test-result: PASS" "$ns/results/$name.trs" 2>/dev/null || echo 0)
        fail=$(grep -c ":test-result: FAIL" "$ns/results/$name.trs" 2>/dev/null || echo 0)
        skip=$(grep -c ":test-result: SKIP" "$ns/results/$name.trs" 2>/dev/null || echo 0)
        err=$(grep -c ":test-result: ERROR" "$ns/results/$name.trs" 2>/dev/null || echo 0)
        printf "%s %-18s rc=%s pass=%s fail=%s skip=%s error=%s\n" "$label" "$name" "$rc" "$pass" "$fail" "$skip" "$err"
      done
      kill $dpid 2>/dev/null; wait $dpid 2>/dev/null
    '
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
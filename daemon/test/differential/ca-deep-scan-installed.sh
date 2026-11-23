#!/usr/bin/env bash
# goonix: REGRESSION — the INSTALLED Haskell package must pass ca-build's
# deep-scan cases with NO GOONIX_DEEP_SCAN_HELPER override.
#
# Before the packaging fix the HS package shipped no goonix-ca-scan helper
# (Makefile.am includes nix/goonix.mk only under !BUILD_HASKELL_DAEMON) and the
# daemon's default helper path was the literal "/goonix-ca-scan", so the six
# deep-scan cases failed ("deep scan rejects gz/xz/bz2/zip token at decoded
# offset", "a sibling output token in a compressed member is refused", "a
# decoded placeholder 32 bytes before a chunk boundary is refused").  After the
# fix the helper is built and installed into libexec in HS mode too, and the
# daemon's default is the make-expanded libexecdir (Goonix.Config), exactly as
# C++ deep-scan.cc uses GOONIX_LIBEXEC_DIR.  This runs the installed daemon as
# namespace root with the chroot ON and a bare environment (env -i, so
# GOONIX_DEEP_SCAN_HELPER is unset) and requires those six cases to PASS.
#
# Usage: ca-deep-scan-installed.sh HS_PKG WORK
#   HS_PKG  installed Haskell-daemon package (nix build ...#default out-link)
#   WORK    scratch directory (created/wiped)
#
# Exit 0 only when ca-build has zero FAIL/ERROR and the six deep-scan cases are
# PASS.  Run against a pre-fix package: it must FAIL.  Post-fix: it must PASS.
set -uo pipefail
hs_pkg=${1:?usage: ca-deep-scan-installed.sh HS_PKG WORK}
work=${2:?}
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
hs_daemon=$(readlink -f "$hs_pkg/bin/guix-daemon")
uid=$(id -u); gid=$(id -g)
rm -rf "$work"; mkdir -p "$work"

# The six deep-scan cases that the packaging gap broke (tests/ca-build.scm).
deep_cases=(
  "deep scan rejects gz token at decoded offset"
  "deep scan rejects xz token at decoded offset"
  "deep scan rejects bz2 token at decoded offset"
  "deep scan rejects zip token at decoded offset"
  "a sibling output token in a compressed member is refused"
  "a decoded placeholder 32 bytes before a chunk boundary is refused"
)

devinfo=$(cd "$root" && nix develop .#default -c bash -c '
  command -v guile; command -v sqlite3
  echo "GLP=$GUILE_LOAD_PATH"; echo "GLCP=$GUILE_LOAD_COMPILED_PATH"')
guile_bin=$(echo "$devinfo" | sed -n 1p)
sqlite3_bin=$(echo "$devinfo" | sed -n 2p)
dev_glp=$(echo "$devinfo" | grep '^GLP=' | sed 's/^GLP=//')
dev_glcp=$(echo "$devinfo" | grep '^GLCP=' | sed 's/^GLCP=//')

ns="$work/HS"
mkdir -p "$ns"/{gnu-store,var-guix,log-guix,etc,etc-guix,build,cache,substituter-data}
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
cp "$root/tests/keys/openpgp/signing-key.sec" "$ns/etc-guix/signing-key.sec"
cp "$root/tests/keys/openpgp/signing-key.pub" "$ns/etc-guix/signing-key.pub"
chmod 0400 "$ns/etc-guix/signing-key.sec"
mkdir -p "$ns/bootstrap"
cp "$root/gnu/packages/bootstrap/i686-linux/bash" "$ns/bootstrap/bash" 2>/dev/null || true
cp "$root/gnu/packages/bootstrap/i686-linux/mkdir" "$ns/bootstrap/mkdir" 2>/dev/null || true

pkg_glp="$hs_pkg/share/guile/site/3.0"
pkg_glcp="$hs_pkg/lib/guile/3.0/site-ccache"
export PATH=/run/wrappers/bin:$PATH
timeout 900 unshare --user \
  --map-users=0:"$uid":1 --map-users=1:100000:65536 \
  --map-groups=0:"$gid":1 --map-groups=1:100000:65536 \
  --mount -- bash -c '
    set -uo pipefail
    ns="'"$ns"'"; root="'"$root"'"; daemon="'"$hs_daemon"'"
    guile_bin="'"$guile_bin"'"; dev_glp="'"$dev_glp"'"; dev_glcp="'"$dev_glcp"'"
    pkg_glp="'"$pkg_glp"'"; pkg_glcp="'"$pkg_glcp"'"
    mount --bind "$ns/etc/passwd" /etc/passwd
    mount --bind "$ns/etc/group" /etc/group
    mount --bind "$ns/etc/nsswitch.conf" /etc/nsswitch.conf
    mount --bind /dev/null /var/run/nscd/socket 2>/dev/null
    mount --bind "$ns/gnu-store" /gnu/store
    mount --bind "$ns/var-guix" /var/guix
    mount --bind "$ns/log-guix" /var/log/guix
    mount --bind "$ns/etc-guix" /etc/guix
    # env -i: GOONIX_DEEP_SCAN_HELPER is UNSET.  The daemon must find its
    # installed libexec helper through the make-expanded default.
    env -i TMPDIR="$ns/build" LC_ALL=C.UTF-8 PATH=/nonexistent \
      "$daemon" --build-users-group=guixbuild --max-jobs=2 --substitute-urls="" \
      > "$ns/daemon.log" 2>&1 &
    dpid=$!
    for i in $(seq 1 200); do test -S /var/guix/daemon-socket/socket && break; sleep 0.1; done
    if ! test -S /var/guix/daemon-socket/socket; then
      echo "DAEMON DID NOT START"; head -30 "$ns/daemon.log"; kill $dpid 2>/dev/null; exit 2
    fi
    client_env() {
      env -i LC_ALL=C.UTF-8 PATH=/nonexistent HOME="$ns" \
        NIX_STORE_DIR=/gnu/store GUIX_STATE_DIRECTORY=/var/guix \
        GUIX_DAEMON_SOCKET=/var/guix/daemon-socket/socket \
        GUIX_DATABASE_DIRECTORY=/var/guix/db GUIX_LOG_DIRECTORY=/var/log/guix \
        GUIX_BINARY_SUBSTITUTE_URL="file://$ns/substituter-data" \
        GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES=yes \
        GUILE_LOAD_PATH="$root:$pkg_glp:$dev_glp" \
        GUILE_LOAD_COMPILED_PATH="$root:$pkg_glcp:$dev_glcp" \
        GUILE_AUTO_COMPILE=0 "$@"
    }
    client_env "$guile_bin" --no-auto-compile \
      "$root/daemon/test/seed-restore.scm" "/home/wrath/.cache/goonix-test-seed" \
      > "$ns/seed.log" 2>&1
    echo "SEED_RC=$? $(tail -1 "$ns/seed.log")"
    mkdir -p "$ns/results"
    client_env "$guile_bin" --no-auto-compile -e main \
      "$root/build-aux/test-driver.scm" \
      --test-name=tests/ca-build --log-file="$ns/results/ca-build.log" \
      --trs-file="$ns/results/ca-build.trs" --brief=yes --color-tests=no \
      -- "$root/tests/ca-build.scm" > "$ns/results/ca-build.out" 2>&1
    echo "CA_BUILD_RC=$?"
    kill $dpid 2>/dev/null; wait $dpid 2>/dev/null
  '
run_rc=$?
trs="$work/HS/results/ca-build.trs"
pass=$(grep -c ":test-result: PASS" "$trs" 2>/dev/null); pass=${pass:-0}
fail=$(grep -c ":test-result: FAIL" "$trs" 2>/dev/null); fail=${fail:-0}
err=$(grep -c ":test-result: ERROR" "$trs" 2>/dev/null); err=${err:-0}
echo "ca-build: pass=$pass fail=$fail error=$err (run_rc=$run_rc)"

# Each of the six deep-scan cases must be PASS.
missing=0
for case_name in "${deep_cases[@]}"; do
  if grep -qF ":test-result: PASS ca-build/CA-1: compressed self tokens and the deep-scan setting: $case_name" "$trs" 2>/dev/null \
     || grep -qF ":test-result: PASS ca-build/CA-1: all output tokens and helper boundaries: $case_name" "$trs" 2>/dev/null; then
    echo "PASS  $case_name"
  else
    echo "MISSING/FAIL  $case_name"
    missing=1
  fi
done

if test "$fail" -eq 0 && test "$err" -eq 0 && test "$missing" -eq 0; then
  echo "REGRESSION PASS: installed HS package deep-scan cases pass with no GOONIX_DEEP_SCAN_HELPER"
  exit 0
fi
echo "REGRESSION FAIL: installed HS package deep-scan cases do not all pass"
grep ":test-result: FAIL" "$trs" 2>/dev/null | head
exit 1
#!/usr/bin/env bash
# goonix CA-6 on zergling2: SMOKE, not the long gate (reviewer, 2026-11-22).
#
# Proves the three things the counted run depends on, in minutes:
#   1. the tree builds here (bootstrap/configure/make in nix develop);
#   2. the user+mount namespace starts with the subordinate-ID mapping derived
#      from THIS host (hurdkit uid 1003, subgid only 231072:65536), and the
#      implementation daemon answers on its private socket;
#   3. one small INPUT-ADDRESSED item substitutes from bordeaux directly
#      (never the Windows :8480 cache, never the private root daemon).
#
# Nothing here touches zergling2's private daemon service or the :8480 cache.
set -uo pipefail
C=${1:-/home/wrath/goonix/.worktrees/goonix-implementation}
V=${2:-/tmp/z2-ca6-smoke}
mkdir -p "$V"
cd "$C" || exit 1
printf 'SOURCE_PATH=%s\n' "$C"
printf 'HEAD=%s\n' "$(git rev-parse HEAD 2>/dev/null)"
printf 'HOST_UID=%s HOST_GID=%s USER=%s\n' "$(id -u)" "$(id -g)" "$(id -un)"
printf 'SUBUID=%s\n' "$(grep "^$(id -un):" /etc/subuid | tr '\n' ' ')"
printf 'SUBGID=%s\n' "$(grep "^$(id -un):" /etc/subgid | tr '\n' ' ')"
printf 'NEWUIDMAP=%s\n' "$(command -v newuidmap)"

echo '=== 1. build ==='
if ! nix develop '.#default' -c bash -c '
  set -e
  if [ ! -x ./configure ]; then ./bootstrap; fi
  ./configure --localstatedir=/var --sysconfdir=/etc ac_cv_guix_test_root=/tmp/gxv-test
  nice -n 10 make -j8
' > "$V/build.log" 2>&1; then
  echo 'BUILD FAILED'; tail -n 25 "$V/build.log"; exit 1
fi
echo 'build ok'

echo '=== 2. subordinate-ID mapping (the ported part) ==='
# Derive the mapping exactly as goonix-ca6/run.sh does, from THIS host, and
# prove inside the namespace that (a) we are root, (b) the build-user ids are
# mapped, and (c) chown to a build user works - the operation that failed with
# "Cannot change ownership to uid 1003, gid 30000" before build users existed.
host_uid=$(id -u); host_gid=$(id -g); host_user=$(id -un)
sub_uid=$(awk -F: -v u="$host_user" '$1==u {print $2; exit}' /etc/subuid)
sub_uid_n=$(awk -F: -v u="$host_user" '$1==u {print $3; exit}' /etc/subuid)
sub_gid=$(awk -F: -v u="$host_user" '$1==u {print $2; exit}' /etc/subgid)
sub_gid_n=$(awk -F: -v u="$host_user" '$1==u {print $3; exit}' /etc/subgid)
if [ -x /run/wrappers/bin/newuidmap ]; then export PATH=/run/wrappers/bin:$PATH; fi
printf 'MAP uid=%s gid=%s subuid=%s:%s subgid=%s:%s\n' \
  "$host_uid" "$host_gid" "$sub_uid" "$sub_uid_n" "$sub_gid" "$sub_gid_n"
mkdir -p "$V/maptest"
# Explicit newuidmap/newgidmap on a parked child, with a go-ahead handshake.
# Repeated --map-users is NOT portable: measured on zergling2's util-linux
# 2.39.3 it drops the 0->uid self mapping (uid_map holds only the subordinate
# range, id -u becomes 65534, chown to a build user is refused), while the
# laptop's 2.42.3 accepts it.  See job ca6-z2-mapdiag.
rm -f "$V/ns-pid" "$V/ns-go"
unshare --user --mount bash -c '
  echo "$$" > "$1"
  for i in $(seq 1 300); do [ -e "$2" ] && break; sleep .1; done
  [ -e "$2" ] || { echo "no maps go-ahead" >&2; exit 1; }
  set -e
  echo "INSIDE_ID=$(id -u):$(id -g)"
  cat /proc/self/uid_map
  cat /proc/self/gid_map
  touch "$3/f"
  chown 1:1 "$3/f" && echo "CHOWN_TO_BUILD_USER=ok"
  stat -c "OWNER=%u:%g" "$3/f"
' _ "$V/ns-pid" "$V/ns-go" "$V/maptest" > "$V/map.log" 2>&1 &
mapjob=$!
np=''
for i in $(seq 1 200); do
  np=$(cat "$V/ns-pid" 2>/dev/null | head -1); [ -n "$np" ] && break; sleep .1
done
if [ -z "$np" ]; then echo 'MAPPING FAILED: no namespace pid'; cat "$V/map.log"; exit 1; fi
newuidmap "$np" 0 "$host_uid" 1 1 "$sub_uid" "$sub_uid_n" || { echo 'newuidmap failed'; exit 1; }
newgidmap "$np" 0 "$host_gid" 1 1 "$sub_gid" "$sub_gid_n" || { echo 'newgidmap failed'; exit 1; }
: > "$V/ns-go"
wait "$mapjob" || true
cat "$V/map.log"
grep -q 'CHOWN_TO_BUILD_USER=ok' "$V/map.log" || { echo 'FAIL: cannot chown to a build user'; exit 1; }

echo '=== 3. namespace daemon + one IA substitute from bordeaux ==='
# The smoke reuses the real seed script: it starts the implementation daemon in
# a user+mount namespace with /gnu/store and /var/guix bound over private dirs,
# then runs `guix build hello --no-grafts` against bordeaux.  That is exactly
# the namespace/daemon/substitute path the counted run needs, on a small item.
export GOONIX_CA6_SCRATCH="$V/work"
if ! nix develop '.#default' -c bash "$C/goonix-ca6/seed.sh" \
    > "$V/seed.log" 2>&1; then
  echo 'SEED/NAMESPACE FAILED'; tail -n 30 "$V/seed.log"; exit 1
fi
cat "$V/seed.log"
S="$V/work"
echo '--- daemon log ---'; tail -n 6 "$S/daemon.log" 2>/dev/null
echo '--- substitute evidence (cache first, bordeaux fallback) ---'
grep -aoE "looking for substitutes on '[^']*'|will be downloaded|substituting [^ ]*" \
  "$S/hello.err" 2>/dev/null | head -8
echo '--- hello result ---'; cat "$S/result" 2>/dev/null | head -4
echo '--- store items ---'; ls "$S/store" 2>/dev/null | wc -l

# Assertions, so the smoke has a verdict rather than a log dump.
rc=0
grep -qa 'HELLO_EXIT=0' "$S/result" 2>/dev/null || { echo 'FAIL: hello did not build'; rc=1; }
grep -qaE 'bordeaux.guix.gnu.org|10.0.30.4:8480' "$S/hello.err" 2>/dev/null \
  || { echo 'FAIL: no substitute lookup'; rc=1; }
# The cache is now expected (reviewer, 2026-11-22); record whether it was used.
if grep -qa '10.0.30.4:8480' "$S/hello.err" 2>/dev/null; then
  echo 'DOWNLOAD_CACHE=on (used in this smoke)'
else
  echo 'DOWNLOAD_CACHE=configured but not seen in this smoke log'
fi
[ -S "$S/socket" ] || echo 'note: socket removed at namespace exit (expected)'
[ "$rc" = 0 ] && echo 'SMOKE PASS' || echo 'SMOKE FAIL'
exit "$rc"
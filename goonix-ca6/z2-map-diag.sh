#!/usr/bin/env bash
# goonix CA-6 on zergling2: diagnose the subordinate-ID mapping failure.
# Smoke ca6-z2-smoke1 showed INSIDE_ID=65534:65534 and a uid_map holding ONLY
# "1 231072 65536" - the 0->1003 self mapping was never written, so the caller's
# own uid is unmapped inside and chown to a build user is refused.
# No build needed; this is pure namespace/newuidmap behaviour.
set -uo pipefail
V=${1:-/tmp/z2-map-diag}
mkdir -p "$V"; cd "$V" || exit 1
u=$(id -u); g=$(id -g); n=$(id -un)
su=$(awk -F: -v x="$n" '$1==x {print $2; exit}' /etc/subuid)
sun=$(awk -F: -v x="$n" '$1==x {print $3; exit}' /etc/subuid)
sg=$(awk -F: -v x="$n" '$1==x {print $2; exit}' /etc/subgid)
sgn=$(awk -F: -v x="$n" '$1==x {print $3; exit}' /etc/subgid)
printf 'HOST uid=%s gid=%s user=%s subuid=%s:%s subgid=%s:%s\n' "$u" "$g" "$n" "$su" "$sun" "$sg" "$sgn"
printf 'newuidmap=%s setuid?=%s\n' "$(command -v newuidmap)" "$(stat -c %A "$(command -v newuidmap)")"
printf 'unshare=%s\n' "$(unshare --version 2>&1 | head -1)"
printf 'max_user_namespaces=%s\n' "$(cat /proc/sys/user/max_user_namespaces 2>/dev/null)"

echo '--- A: baseline single mapping (--map-root-user) ---'
unshare --user --map-root-user --mount bash -c 'echo "A_ID=$(id -u):$(id -g)"; cat /proc/self/uid_map' 2>&1 | head -5

echo '--- B: two ranges, self first (what run.sh does) ---'
unshare --user --map-users=0:"$u":1 --map-users=1:"$su":"$sun" \
        --map-groups=0:"$g":1 --map-groups=1:"$sg":"$sgn" \
        --mount bash -c 'echo "B_ID=$(id -u):$(id -g)"; cat /proc/self/uid_map; cat /proc/self/gid_map' 2>&1 | head -8

echo '--- C: two ranges, subordinate first then self ---'
unshare --user --map-users=1:"$su":"$sun" --map-users=0:"$u":1 \
        --map-groups=1:"$sg":"$sgn" --map-groups=0:"$g":1 \
        --mount bash -c 'echo "C_ID=$(id -u):$(id -g)"; cat /proc/self/uid_map' 2>&1 | head -6

echo '--- D: comma-separated single option ---'
unshare --user --map-users=0:"$u":1,1:"$su":"$sun" \
        --map-groups=0:"$g":1,1:"$sg":"$sgn" \
        --mount bash -c 'echo "D_ID=$(id -u):$(id -g)"; cat /proc/self/uid_map' 2>&1 | head -6

echo '--- E: explicit newuidmap on a parked namespace (shows its stderr) ---'
unshare --user --mount bash -c 'echo "PARKED_PID=$$"; sleep 8' > "$V/park.out" 2>&1 &
sleep 2
pp=$(sed -n 's/PARKED_PID=//p' "$V/park.out" | head -1)
echo "parked pid=$pp"
if [ -n "$pp" ]; then
  newuidmap "$pp" 0 "$u" 1 1 "$su" "$sun" 2>&1 | head -3
  echo "newuidmap rc=$?"
  newgidmap "$pp" 0 "$g" 1 1 "$sg" "$sgn" 2>&1 | head -3
  echo "newgidmap rc=$?"
  cat /proc/"$pp"/uid_map 2>/dev/null
  cat /proc/"$pp"/gid_map 2>/dev/null
fi
wait 2>/dev/null
echo 'DIAG DONE'
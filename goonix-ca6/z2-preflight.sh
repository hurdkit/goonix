#!/usr/bin/env bash
# goonix CA-6 on zergling2: pre-flight EVERY namespace prerequisite the gate's
# part script needs, in seconds, instead of discovering them one per long run.
# Each failure so far was a NixOS assumption: /run/nscd exists (counted1),
# /var/empty creatable (counted2).  This checks the rest of that list at once.
set -uo pipefail
V=${1:-/tmp/z2-ca6-preflight}
# The scratch tree must NOT live under /tmp: the part script mounts a private
# tmpfs over /tmp for the build users, which HIDES anything below it.  With the
# scratch under /tmp the daemon's state dir, socket and the build users' home
# all vanish mid-run (measured: 'build home writable ... No such file or
# directory' in job ca6-z2-preflight).  Keep it under the mirrored home.
case "$V" in /tmp/*) V="/home/wrath/z2-ca6-preflight";; esac
mkdir -p "$V"; S="$V/work"; mkdir -p "$S/store" "$S/var" "$S/etc" "$S/log" "$S/var-empty"
u=$(id -u); g=$(id -g); n=$(id -un)
su=$(awk -F: -v x="$n" '$1==x {print $2; exit}' /etc/subuid)
sun=$(awk -F: -v x="$n" '$1==x {print $3; exit}' /etc/subuid)
sg=$(awk -F: -v x="$n" '$1==x {print $2; exit}' /etc/subgid)
sgn=$(awk -F: -v x="$n" '$1==x {print $3; exit}' /etc/subgid)
printf 'root:x:0:0:root:/root:/bin/sh\nnobody:x:65534:65534:nobody:%s:/bin/false\n' "$S/var-empty" > "$S/etc/passwd.ns"
for i in $(seq 0 9); do printf 'guixbuilder%d:x:%d:1:b%d:%s:/bin/false\n' "$i" "$((i+1))" "$i" "$S/var-empty" >> "$S/etc/passwd.ns"; done
{ printf 'root:x:0:\nusers:x:%s:\nguixbuild:x:1:' "$g"
  for i in $(seq 0 9); do printf 'guixbuilder%d' "$i"; [ "$i" -lt 9 ] && printf ','; done
  printf '\nnogroup:x:65534:\n'; } > "$S/etc/group.ns"

cat > "$S/probe.sh" <<PROBE
set -uo pipefail
fail=0
try() { printf '%-34s' "\$1"; shift; if "\$@" 2>/dev/null; then echo OK; else echo FAIL; fail=1; fi; }
echo "INSIDE_ID=\$(id -u):\$(id -g)"
try 'bind store'      mount --bind '$S/store' /gnu/store
try 'bind var/guix'   mount --bind '$S/var' /var/guix
try 'bind passwd'     mount --bind '$S/etc/passwd.ns' /etc/passwd
try 'bind group'      mount --bind '$S/etc/group.ns' /etc/group
printf '%-34s' 'nscd mask (optional)'; { [ -d /run/nscd ] || mkdir -p /run/nscd; } 2>/dev/null && mount -t tmpfs tmpfs /run/nscd 2>/dev/null && echo OK || echo 'SKIP/absent'
printf '%-34s' 'mkdir /var/empty (optional)'; mkdir -p /var/empty 2>/dev/null && echo OK || echo 'DENIED (home falls back to scratch)'
try 'tmpfs /tmp'      mount -t tmpfs -o mode=1777 tmpfs /tmp
printf '%-34s' 'getent guixbuild'; getent group guixbuild || echo MISSING
printf '%-34s' 'getent guixbuilder0'; getent passwd guixbuilder0 || echo MISSING
printf '%-34s' 'build home writable'; touch '$S/var-empty/t' && echo OK || { echo FAIL; fail=1; }
printf '%-34s' 'chown to build user'; touch /tmp/ct && chown 1:1 /tmp/ct && echo OK || { echo FAIL; fail=1; }
printf '%-34s' 'store writable as root'; touch /gnu/store/.w && rm -f /gnu/store/.w && echo OK || { echo FAIL; fail=1; }
echo "PREFLIGHT_FAIL=\$fail"
PROBE

rm -f "$V/ns-pid" "$V/ns-go"
unshare --user --mount bash -c '
  echo "$$" > "$1"
  for i in $(seq 1 300); do [ -e "$2" ] && break; sleep .1; done
  [ -e "$2" ] || exit 1
  exec bash "$3"
' _ "$V/ns-pid" "$V/ns-go" "$S/probe.sh" > "$V/probe.log" 2>&1 &
j=$!
np=''
for i in $(seq 1 200); do np=$(cat "$V/ns-pid" 2>/dev/null|head -1); [ -n "$np" ] && break; sleep .1; done
[ -n "$np" ] || { echo 'no namespace pid'; cat "$V/probe.log"; exit 1; }
newuidmap "$np" 0 "$u" 1 1 "$su" "$sun" || exit 1
newgidmap "$np" 0 "$g" 1 1 "$sg" "$sgn" || exit 1
: > "$V/ns-go"
wait "$j" || true
cat "$V/probe.log"
grep -q 'PREFLIGHT_FAIL=0' "$V/probe.log" && echo 'PREFLIGHT PASS' || echo 'PREFLIGHT FAIL'
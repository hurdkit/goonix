#!/usr/bin/env bash
# goonix: make a tiny store and its metadata.  No system-store contents or DB.
set -eu
if test "$#" -ne 2; then echo "usage: prepare-readonly-fixture.sh ROOT STORE-PREFIX" >&2; exit 2; fi
root=$1
prefix=$2
store=$prefix/store
mkdir -p "$root/db" "$root/var/gcroots" "$root/var/profiles" "$store"
schema=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)/guix/store/schema.sql
sqlite3 "$root/db/db.sqlite" < "$schema"
printf 7 > "$root/db/schema"
foo=$store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo
bar=$store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-bar
drv=$store/cccccccccccccccccccccccccccccccc-foo.drv
other=$store/dddddddddddddddddddddddddddddddd-other.drv
empty=$store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-empty
printf 'tiny fixture\n' > "$foo"
printf 'reference: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$bar"
printf 'Derive([("out","%s","","")],[("%s",["out"])],[],"x86_64-linux","/bin/sh",["-c","true"],[])\n' "$foo" "$other" > "$drv"
printf 'Derive([("out","%s","","")],[],[],"x86_64-linux","/bin/sh",["-c","true"],[])\n' "$foo" > "$other"
printf 'unused\n' > "$store/ffffffffffffffffffffffffffffffff-unused"
: > "$empty"
chmod 0555 "$foo" "$bar" "$drv" "$other" "$empty" "$store/ffffffffffffffffffffffffffffffff-unused"
ln -s "$foo" "$root/var/gcroots/direct"
ln -s "$root/var/gcroots/indirect-target" "$root/var/gcroots/indirect"
ln -s "$bar" "$root/var/gcroots/indirect-target"
ln -s "$store/ffffffffffffffffffffffffffffffff-unused" "$root/var/gcroots/invalid"
# A directory name and a file whose basename is a valid store item are both
# intentionally visited by the C++ root walker.
printf 'profile\n' > "$root/var/profiles/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo"
escaped() { printf '%s' "$1" | sed "s/'/''/g"; }
insert_path() {
  path=$1; hash=$2; time=$3; deriver=$4; size=$5
  sqlite3 "$root/db/db.sqlite" "insert into ValidPaths(path,hash,registrationTime,deriver,narSize) values ('$(escaped "$path")','$hash',$time,$(if test -n "$deriver"; then printf "'%s'" "$(escaped "$deriver")"; else printf NULL; fi),$size);"
}
insert_path "$foo" sha256:1111111111111111111111111111111111111111111111111111111111111111 1700000001 "$drv" 128
insert_path "$bar" sha256:2222222222222222222222222222222222222222222222222222222222222222 1700000002 "$other" 144
insert_path "$drv" sha256:3333333333333333333333333333333333333333333333333333333333333333 1700000003 '' 160
insert_path "$other" sha256:4444444444444444444444444444444444444444444444444444444444444444 1700000004 '' 176
insert_path "$empty" sha256:5555555555555555555555555555555555555555555555555555555555555555 1700000005 '' 112
sqlite3 "$root/db/db.sqlite" <<SQL
insert into Refs values ((select id from ValidPaths where path='$(escaped "$bar")'),(select id from ValidPaths where path='$(escaped "$foo")'));
insert into Refs values ((select id from ValidPaths where path='$(escaped "$foo")'),(select id from ValidPaths where path='$(escaped "$foo")'));
insert into DerivationOutputs values ((select id from ValidPaths where path='$(escaped "$drv")'),'out','$(escaped "$foo")');
insert into DerivationOutputs values ((select id from ValidPaths where path='$(escaped "$other")'),'out','$(escaped "$bar")');
insert into FailedPaths values ('$(escaped "$store/ffffffffffffffffffffffffffffffff-failed")',1700000006);
SQL
printf '%s\n' "$foo" > "$root/query-path"

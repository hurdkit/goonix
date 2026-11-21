#!/bin/sh
# Compare every recorded test name, not aggregate Automake file results.
set -eu
if test "$#" -ne 2; then
    echo "usage: $0 BASELINE-DIRECTORY ACTUAL-DIRECTORY" >&2
    exit 2
fi
baseline=$1
actual=$2
fail=0
for expected in "$baseline"/*.trs
do
    test -f "$expected" || continue
    name=${expected##*/}
    observed=$actual/$name
    if test ! -f "$observed"
    then
        printf 'MISSING %s\n' "$name"
        fail=1
        continue
    fi
    awk -F ':test-result: ' '/^:test-result:/ {
        sub(/ \[[0-9][0-9]*\.[0-9][0-9]*s\]$/, "", $2)
        print $2
    }' "$expected" | sort > "$baseline/.$name.names"
    awk -F ':test-result: ' '/^:test-result:/ {
        sub(/ \[[0-9][0-9]*\.[0-9][0-9]*s\]$/, "", $2)
        print $2
    }' "$observed" | sort > "$actual/.$name.names"
    if ! cmp -s "$baseline/.$name.names" "$actual/.$name.names"
    then
        printf 'CHANGED %s\n' "$name"
        diff -u "$baseline/.$name.names" "$actual/.$name.names" || :
        fail=1
    else
        printf 'UNCHANGED %s\n' "$name"
    fi
done
for observed in "$actual"/*.trs
do
    test -f "$observed" || continue
    name=${observed##*/}
    test -f "$baseline/$name" || {
        printf 'UNEXPECTED %s\n' "$name"
        fail=1
    }
done
exit "$fail"

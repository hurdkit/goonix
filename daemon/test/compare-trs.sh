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
# A comparison of NOTHING is not agreement.  Both directories empty (a run that
# died before producing any .trs) used to fall through every loop and exit 0,
# which the counted gate printed as ALL NAMES IDENTICAL - a green gate with zero
# tests.  Require at least one recorded suite on each side.
baseline_count=0
actual_count=0
for f in "$baseline"/*.trs; do test -f "$f" && baseline_count=$((baseline_count + 1)); done
for f in "$actual"/*.trs; do test -f "$f" && actual_count=$((actual_count + 1)); done
if test "$baseline_count" -eq 0 || test "$actual_count" -eq 0; then
    printf 'EMPTY_COMPARISON baseline=%s actual=%s\n' "$baseline_count" "$actual_count"
    exit 1
fi
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

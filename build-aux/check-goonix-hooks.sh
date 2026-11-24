#!/usr/bin/env bash
# goonix: check the boundary between upstream Guix and goonix.
#
# goonix adds files of its own and touches upstream's files only through
# hooks: a few lines that call into one of our files.  This script checks
# every file that exists upstream and differs from it:
#
#   - nothing under gnu/packages or gnu/services differs, and no upstream
#     file is deleted;
#   - every group of added lines contains the mark "goonix:", and no group
#     only removes upstream lines;
#   - the file is listed in build-aux/goonix-hooks.txt, and its added and
#     removed lines do not exceed what is recorded there, so that a hook
#     cannot grow without the list changing in the same commit;
#   - it adds no more than LIMIT lines: beyond that it is logic, which
#     belongs in a file of ours;
#   - no group removes more than REMOVE_LIMIT upstream lines: upstream's
#     code stays where upstream has it.  Moved into a file of ours, or
#     written again there, it no longer merges with upstream's changes.
#
# Files that upstream does not have are ours and are not checked.
#
# usage: check-goonix-hooks.sh            check; exit 0, 1, or 77 (skipped)
#        check-goonix-hooks.sh --list     print FILE ADDED REMOVED, as found
#        check-goonix-hooks.sh --record   rewrite the list from the tree
set -euo pipefail

LIMIT=50
REMOVE_LIMIT=8

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
list="build-aux/goonix-hooks.txt"
mode="${1:-check}"

skip() {
    echo "goonix hooks: skipped: $*" >&2
    exit 77
}

# Without the history there is nothing to compare with.  That is a skip,
# never a pass.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || skip "not a Git checkout"
base="${GOONIX_UPSTREAM_BASE:-$(cat build-aux/goonix-upstream-base)}"
git cat-file -e "$base^{commit}" 2>/dev/null \
    || skip "upstream commit $base is not in this repository"

changed="$(git diff --no-ext-diff --no-renames --name-status "$base" --)" \
    || skip "git diff failed"

failures=0
fail() {
    echo "goonix hooks: $*" >&2
    failures=1
}

# Print "ADDED REMOVED UNMARKED REMOVALS MOVED" for FILE: its added and
# removed lines, the number of groups of added lines without the mark, the
# number of groups that only remove lines, and the number of groups that
# remove more than REMOVE_LIMIT lines.
measure() {
    git diff --no-ext-diff --no-renames --unified=0 "$base" -- "$1" |
        awk -v remove_limit="$REMOVE_LIMIT" '
          function close_hunk() {
              if (inhunk) {
                  if (plus > 0 && !marked) unmarked++
                  if (plus == 0 && minus > 0) removals++
                  if (minus > remove_limit) moved++
              }
              plus = 0; minus = 0; marked = 0
          }
          /^@@/ { close_hunk(); inhunk = 1; next }
          !inhunk { next }
          /^\+/ { plus++; added++; if ($0 ~ /goonix:/) marked = 1; next }
          /^-/ { minus++; removed++; next }
          END { close_hunk()
                printf "%d %d %d %d %d\n", added, removed, unmarked,
                       removals, moved }'
}

recorded() {
    [[ -f "$list" ]] || return 0
    awk -v file="$1" '$1 == file { print $2, $3 }' "$list"
}

declare -a rows=()
while IFS=$'\t' read -r status file; do
    [[ -n "$file" ]] || continue
    case "$status" in
        A) continue ;;                  # ours
        D) fail "$file: an upstream file is deleted"; continue ;;
    esac
    case "$file" in
        gnu/packages/*|gnu/services/*)
            fail "$file: the package and service collections are not edited"
            continue ;;
    esac

    read -r added removed unmarked removals moved < <(measure "$file")
    rows+=("$file $added $removed")
    [[ "$mode" == check ]] || continue

    if ((unmarked > 0)); then
        fail "$file: $unmarked group(s) of added lines without a goonix: mark"
    fi
    if ((removals > 0)); then
        fail "$file: $removals group(s) only remove upstream lines"
    fi
    if ((moved > 0)); then
        fail "$file: $moved group(s) remove more than $REMOVE_LIMIT upstream lines: restore them and call into a file of ours"
    fi
    if ((added > LIMIT)); then
        fail "$file: adds $added lines, more than $LIMIT: move the logic into a file of ours"
    fi
    entry="$(recorded "$file")"
    if [[ -z "$entry" ]]; then
        fail "$file: not listed in $list"
    else
        read -r max_added max_removed <<<"$entry"
        if ((added != max_added || removed != max_removed)); then
            fail "$file: +$added -$removed differs from the recorded +$max_added -$max_removed"
        fi
    fi
done <<<"$changed"

case "$mode" in
    --list)
        printf '%s\n' "${rows[@]}" | sort
        exit 0 ;;
    --record)
        {
            echo "# Upstream files that goonix changes, with the lines added and removed."
            echo "# Checked by build-aux/check-goonix-hooks.sh; rewrite with --record."
            printf '%s\n' "${rows[@]}" | sort
        } >| "$list"
        exit 0 ;;
esac

# A listed file that no longer differs must leave the list.
if [[ -f "$list" ]]; then
    while read -r file _; do
        case "$file" in ''|'#'*) continue ;; esac
        printf '%s\n' "${rows[@]}" | grep -q "^$file " \
            || fail "$file: listed in $list but unchanged"
    done < "$list"
fi

if ((failures == 0)); then
    echo "goonix hooks: every change to an upstream file is a marked hook"
fi
exit "$failures"

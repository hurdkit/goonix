#!/bin/sh
# Generate bounded, read-only format vectors from a populated Guix store.
set -eu

if test "$#" -ne 3; then
    echo "usage: $0 STORE OUTPUT-DIRECTORY GHC" >&2
    exit 2
fi
store=$1
out=$2
ghc=$3
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
test ! -e "$out" || {
    echo "refusing to overwrite existing vector directory: $out" >&2
    exit 2
}

# The whole-store pass emits only hashes and sizes.  Raw archives are kept
# only for a deterministic sample with a hard total byte cap.
sample_cap=268435456
mkdir -p "$out/bin" "$out/build" "$out/derivations" "$out/nar"
"$ghc" --make -XGHC2024 -O0 -outputdir "$out/build" \
    -o "$out/bin/copy-derivations" "$root/test/vectors/Generate.hs"
"$out/bin/copy-derivations" "$store" "$out"

cxx=${CXX:-c++}
common="-std=c++20 -I$root/../nix -I$root/../nix/libutil"
# shellcheck disable=SC2086
"$cxx" $common "$root/test/vectors/hash-nar.cc" \
    "$root/../nix/libutil/archive.cc" "$root/../nix/libutil/serialise.cc" \
    "$root/../nix/libutil/hash.cc" "$root/../nix/libutil/util.cc" \
    "$root/../nix/libutil/affinity.cc" -lgcrypt -o "$out/bin/hash-nar"
# shellcheck disable=SC2086
"$cxx" $common "$root/test/vectors/dump-nar.cc" \
    "$root/../nix/libutil/archive.cc" "$root/../nix/libutil/serialise.cc" \
    "$root/../nix/libutil/util.cc" "$root/../nix/libutil/affinity.cc" \
    -o "$out/bin/dump-nar"
"$cxx" $common -o "$out/bin/inspect-item" \
    "$root/test/vectors/inspect-item.cc" "$root/../nix/libutil/util.cc" \
    "$root/../nix/libutil/affinity.cc"

# Link only the baseline C++ libraries.  This oracle reads copied vector
# files and does not instantiate a store or connect to a daemon.
# goonix: globals.cc needs the same configured path macros as libstore.
common="$common -DNIX_STORE_DIR=\\\"/gnu/store\\\" -DNIX_STATE_DIR=\\\"/var/guix\\\" -DNIX_LOG_DIR=\\\"/var/log/guix\\\" -DGUIX_CONFIGURATION_DIRECTORY=\\\"/etc/guix\\\" -DNIX_BIN_DIR=\\\"/usr/bin\\\""
"$cxx" $common -I"$root/../nix/libstore" \
    "$root/test/vectors/hash-derivations.cc" \
    "$root/../nix/libstore/derivations.cc" "$root/../nix/libstore/globals.cc" \
    "$root/../nix/libstore/store-api.cc" \
    "$root/../nix/libutil/hash.cc" "$root/../nix/libutil/serialise.cc" \
    "$root/../nix/libutil/archive.cc" "$root/../nix/libutil/util.cc" "$root/../nix/libutil/affinity.cc" \
    -lgcrypt -o "$out/bin/hash-derivations"

"$out/bin/hash-nar" "$store" "$out/nar-hashes.tsv"
"$out/bin/hash-derivations" "$out/derivations" "$out/derivation-hashes.tsv"
find "$out/derivations" -maxdepth 1 -type f | sort > "$out/derivation-files"
"$out/bin/inspect-item" "$store" "$out/sample-candidates.tsv"
: > "$out/sample-manifest.tsv"
sample_bytes=0
sampled_items=
sort -t "$(printf '\t')" -k1,1 -k2,2 "$out/sample-candidates.tsv" |
while IFS="$(printf '\t')" read -r kind name entry
do
    case ":$sampled_items:" in
        *":$name:"*)
            if test -f "$out/nar/$name.nar"
            then
                size=$(wc -c < "$out/nar/$name.nar")
                printf '%s\t%s\t%s\n' "$kind" "$name" "$size" >> "$out/sample-manifest.tsv"
            fi
            continue ;;
    esac
    sampled_items="$sampled_items:$name"
    # Hashing the store is streaming; only a candidate that fits the
    # remaining sample budget is ever written as an archive.
    size=$(awk -F '\t' -v n="$name" '$1 == n {print $4; exit}' "$out/nar-hashes.tsv")
    test -n "$size"
    if test "$size" -gt "$((sample_cap - sample_bytes))"
    then
        continue
    fi
    output="$out/nar/$name.nar"
    "$out/bin/dump-nar" "$store/$name" "$output"
    size=$(wc -c < "$output")
    expected=$(awk -F '\t' -v n="$name" '$1 == n {print $4; exit}' "$out/nar-hashes.tsv")
    test "$size" = "$expected"
    if test "$((sample_bytes + size))" -le "$sample_cap"
    then
        printf '%s\t%s\t%s\n' "$kind" "$name" "$size" >> "$out/sample-manifest.tsv"
        sample_bytes=$((sample_bytes + size))
    else
        rm -f "$output"
    fi
done
sample_count=$(wc -l < "$out/sample-manifest.tsv")
for kind in regular executable symlink directory empty-file empty-directory large-file
do
    grep -q "^$kind	" "$out/sample-manifest.tsv" || {
        echo "sample has no $kind node" >&2
        exit 1
    }
done

{
    printf 'store=%s\n' "$store"
    printf 'derivations=%s\n' "$(find "$out/derivations" -type f | wc -l)"
    printf 'hashed-items=%s\n' "$(wc -l < "$out/nar-hashes.tsv")"
    printf 'modulo-hashes=%s\n' "$(wc -l < "$out/derivation-hashes.tsv")"
    printf 'sample-items=%s\n' "$sample_count"
    printf 'sample-cap=%s\n' "$sample_cap"
} > "$out/manifest"
(cd "$out" && find derivations nar -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$out" && sha256sum derivation-hashes.tsv >> SHA256SUMS)

#!/usr/bin/env bash
# Packaging regression: every tracked Haskell module under daemon/src/Goonix must
# be listed in daemon/guix-daemon.cabal exposed-modules, so a clean cabal/package
# build (nix build .#guix-daemon-hs, haskellProjects) finds it.  The worktree
# `ghc --make -i daemon/src` build hides omissions (it searches the source tree);
# the cabal build does not.  Zergling2 hit this: Goonix.Store.GuixProgram was
# tracked and imported by Archive/Engine but absent from exposed-modules, so
# `nix build .#guix-daemon-hs` failed "Could not find module Goonix.Store.GuixProgram".
#
# Fails if any tracked module is missing from the cabal file.  Deterministic,
# no build needed.  Usage: cabal-modules.sh [TREE]
set -uo pipefail
root=${1:-$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)}
cabal="$root/daemon/guix-daemon.cabal"
test -f "$cabal" || { echo "no cabal file: $cabal"; exit 2; }
rc=0
# Enumerate tracked modules (git ls-files) so an untracked scratch file does not
# count; fall back to a filesystem walk outside a git checkout.
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  files=$(git -C "$root" ls-files 'daemon/src/Goonix/*.hs' 'daemon/src/Goonix/**/*.hs')
else
  files=$(cd "$root" && find daemon/src/Goonix -name '*.hs' | sort)
fi
while read -r f; do
  test -n "$f" || continue
  mod=$(echo "$f" | sed 's|daemon/src/||; s|/|.|g; s|\.hs$||')
  if ! grep -qE "^[[:space:]]*$mod([[:space:]]|$)" "$cabal"; then
    echo "MISSING from cabal exposed-modules: $mod ($f)"
    rc=1
  fi
done <<< "$files"
if test $rc -eq 0; then
  echo "PASS: all tracked Goonix modules are in cabal exposed-modules"
else
  echo "FAIL: a clean cabal/package build would not find the modules above"
fi
exit $rc
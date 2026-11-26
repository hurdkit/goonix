#!/usr/bin/env bash
# Regression: after a rebuild, a CXX run of daemon/test/gate-file.sh followed
# by an HS run must test the Haskell daemon that was just built.
#
# gate-file.sh in CXX mode copies the C++ daemon over ./guix-daemon and puts
# the Haskell daemon back from .scratch/guix-daemon-haskell on exit.  That
# slot used to be filled by HS runs only, so the first CXX run after a rebuild
# replaced the new Haskell daemon with the slot's old one, and the HS run
# after it tested the old one.
#
# No daemon, store or test root: the real gate-file.sh and lib.sh run in a
# scratch tree whose daemons are marked text files, whose test-env does
# nothing and whose `make' records which daemon is in place while "the test"
# runs.
#
# Usage: gate-file-slot.sh [TREE]
set -euo pipefail
root=${1:-$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tree="$work/tree"
mkdir -p "$tree/daemon/test" "$tree/.scratch" "$tree/tests" "$work/bin"
# The source directories gate-file.sh compares the daemons' ages with.
mkdir -p "$tree/daemon/src" "$tree/daemon/app" "$tree/daemon/cbits" \
  "$tree/nix/libstore" "$tree/nix/libutil" "$tree/nix/nix-daemon"
cp "$root/daemon/test/gate-file.sh" "$root/daemon/test/lib.sh" "$tree/daemon/test/"
# gate-file.sh tells the implementations apart by these symbols.
daemon() { printf '#!/bin/sh\n# %s %s\n' "$1" "$2" > "$3"; chmod +x "$3"; }
printf '#!/bin/sh\nexit 0\n' > "$tree/test-env"
chmod +x "$tree/test-env"
cat > "$work/bin/make" <<MAKE
#!/bin/sh
# Stands for \`make check TESTS=tests/probe.sh': note the daemon under test.
sed -n 2p "$tree/guix-daemon" >> "$work/tested"
printf ':test-result: PASS\n' > "$tree/tests/probe.trs"
: > "$tree/tests/probe.log"
MAKE
chmod +x "$work/bin/make"
gate() { ( cd "$tree" && PATH="$work/bin:$PATH" bash daemon/test/gate-file.sh "$1" tests/probe.sh 60 ) > "$work/gate.log" 2>&1 \
  || { echo "FAIL: gate-file.sh $1 exited with an error:"; cat "$work/gate.log"; exit 1; }; }
tested() { tail -n 1 "$work/tested"; }
check() { # what expected actual
  test "$2" = "$3" || { echo "FAIL: $1: expected \`$2', found \`$3'"; exit 1; }
}

# An HS run at an earlier build leaves that daemon in the slot.
daemon GoonixziStore old "$tree/guix-daemon"
gate HS
check "the first HS run tests the tree's daemon" "# GoonixziStore old" "$(tested)"

# The tree is rebuilt: a new Haskell daemon, and a C++ daemon in its slot.
daemon GoonixziStore new "$tree/guix-daemon"
daemon _ZN3nix cxx "$tree/.scratch/hs0-cxx-daemon"
gate CXX
check "the CXX run tests the C++ daemon" "# _ZN3nix cxx" "$(tested)"
check "the CXX run puts the new Haskell daemon back" "# GoonixziStore new" "$(sed -n 2p "$tree/guix-daemon")"
gate HS
check "the HS run after it tests the new Haskell daemon" "# GoonixziStore new" "$(tested)"

# A CXX run that finds a C++ daemon in place (its predecessor was killed
# before its restore) must not put that into the Haskell slot.
cp "$tree/.scratch/hs0-cxx-daemon" "$tree/guix-daemon"
gate CXX
check "a C++ daemon left in place does not enter the Haskell slot" "# GoonixziStore new" "$(sed -n 2p "$tree/.scratch/guix-daemon-haskell")"
check "and the Haskell daemon is put back" "# GoonixziStore new" "$(sed -n 2p "$tree/guix-daemon")"
echo "gate-file keeps the rebuilt Haskell daemon across a CXX run: PASS"

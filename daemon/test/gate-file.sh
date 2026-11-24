#!/usr/bin/env bash
# Compile-first, seeded, one-file Guix gate runner.  The C++ timing controls
# the Haskell limit; the memory cap stays in daemon/test/lib.sh.
#
# A run must test the daemons built from the CURRENT tree, and must never report
# a result it did not produce.  Three ways this script used to do neither:
#   - the Haskell slot was copied only when ABSENT, so after the first run it
#     stayed frozen forever and every later "HS" run tested that old binary;
#   - the CXX slot was whatever .scratch/hs0-cxx-daemon happened to be, with no
#     check that it was newer than the C++ sources it is meant to represent;
#   - `cp tests/$name.trs ... || true` left the PREVIOUS result.trs in place when
#     a run produced none (e.g. the seed died outside the dev shell), and an old
#     file then read as a pass.
# Each is now refused loudly instead.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
cd "$root"
. daemon/test/lib.sh
mode=${1:?usage: gate-file.sh CXX|HS TEST-FILE [TIMEOUT]}
test_file=${2:?test file}
case "$test_file" in tests/*.scm|tests/*.sh) ;; *) echo 'not a Guix test file' >&2; exit 2;; esac
name=${test_file##*/}
name=${name%.*}
# Automake writes a test's result BESIDE the test file: tests/import/foo.scm
# produces tests/import/foo.trs, not tests/foo.trs.  Deriving the result path
# from the basename made every tests/import/* run report NO_RESULT_PRODUCED on
# both daemons, which the parity sweep then read as a CHANGED verdict.  The
# scratch directory also keys off the whole path (slashes as dashes), so
# tests/foo.scm and tests/x/foo.scm cannot share one result slot.
base=${test_file%.*}
trs_file="$base.trs"
log_file="$base.log"
slot=$(printf '%s' "$base" | tr '/.' '--')
scratch="$root/.scratch/gate-$mode-$slot"
mkdir -p "$scratch"
export GOONIX_TEST_TIMEOUT=${3:-${GOONIX_TEST_TIMEOUT:-600}}

# --- the daemon under test must be CURRENT and be the RIGHT implementation ---
# Identity is read from the binary, not from the file name: the Haskell daemon
# carries Goonix module symbols and no nix:: ones, the C++ daemon the reverse.
# `grep -a` treats the binary as text; -c counts matching "lines", so >0 is the
# test, not the count itself.
has_symbol() { grep -ac "$2" "$1" 2>/dev/null || true; }

require_impl() { # binary expected-marker forbidden-marker label
  local bin=$1 want=$2 unwant=$3 label=$4
  test -x "$bin" || { echo "STALE_BINARY $label: $bin is missing or not executable"; exit 2; }
  if test "$(has_symbol "$bin" "$want")" -eq 0; then
    echo "WRONG_IMPLEMENTATION $label: $bin has no $want symbols"; exit 2
  fi
  if test "$(has_symbol "$bin" "$unwant")" -ne 0; then
    echo "WRONG_IMPLEMENTATION $label: $bin carries $unwant symbols"; exit 2
  fi
}

# Any source newer than the binary means the binary does not describe this tree.
newer_sources() { # binary dirs...
  local bin=$1; shift
  find "$@" -type f \( -name '*.hs' -o -name '*.c' -o -name '*.cc' -o -name '*.hh' \) \
    -newer "$bin" -print 2>/dev/null | head -5
}

case "$mode" in
  HS)
    # ALWAYS refresh the slot from the freshly built worktree daemon.  The old
    # `test ! -e` guard made the first copy permanent.
    test -x "$root/guix-daemon" || { echo 'STALE_BINARY HS: build guix-daemon first'; exit 2; }
    require_impl "$root/guix-daemon" 'GoonixziStore' '_ZN3nix' 'HS worktree guix-daemon'
    stale=$(newer_sources "$root/guix-daemon" daemon/src daemon/app daemon/cbits)
    if test -n "$stale"; then
      echo 'STALE_BINARY HS: guix-daemon is older than these sources; rebuild it:'
      printf '%s\n' "$stale"
      exit 2
    fi
    cp "$root/guix-daemon" "$root/.scratch/guix-daemon-haskell"
    ;;
  CXX)
    # The C++ slot is built by the caller (configure --disable-haskell + make).
    # Refuse one that predates the C++ sources rather than silently comparing
    # against an old daemon.
    require_impl "$root/.scratch/hs0-cxx-daemon" '_ZN3nix' 'GoonixziStore' 'CXX .scratch/hs0-cxx-daemon'
    stale=$(newer_sources "$root/.scratch/hs0-cxx-daemon" nix/libstore nix/libutil nix/nix-daemon)
    if test -n "$stale"; then
      echo 'STALE_BINARY CXX: .scratch/hs0-cxx-daemon is older than these sources; rebuild it:'
      printf '%s\n' "$stale"
      exit 2
    fi
    ;;
  *) echo 'mode must be CXX or HS' >&2; exit 2;; esac

# The top-level test-env launches $root/guix-daemon, so select the implementation
# explicitly and restore the Haskell binary on every exit.
restore() {
  if test -e "$root/.scratch/guix-daemon-haskell"; then
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      if cp "$root/.scratch/guix-daemon-haskell" "$root/guix-daemon" 2>/dev/null; then
        return 0
      fi
      sleep 0.1
    done
    printf 'warning: could not restore Haskell daemon binary\n' >&2
  fi
}
trap restore EXIT
if test "$mode" = CXX; then
  cp "$root/.scratch/hs0-cxx-daemon" "$root/guix-daemon"
else
  cp "$root/.scratch/guix-daemon-haskell" "$root/guix-daemon"
fi

chmod -R u+rwX test-tmp 2>/dev/null || true
rm -rf test-tmp
# Remove the previous run's artefacts BEFORE running, so a run that produces
# nothing cannot leave an old file to be read as its result.
rm -f "$trs_file" "$log_file" "$scratch/result.trs" "$scratch/result.log"
if ! ./test-env guile --no-auto-compile /home/wrath/hurdkit/tmp-plans/goonix/tools/seed-restore.scm >"$scratch/seed.log" 2>&1; then
  # `set -e` used to abort here with a bare exit 1 and no explanation, which is
  # how a failed seed came to look like a run that had produced results.
  echo "SEED_FAILED $mode $name: the store was not seeded; no test ran" >&2
  tail -5 "$scratch/seed.log" 2>/dev/null >&2 || true
  exit 2
fi
start=$(date +%s)
set +e
goonix_run_capped make -j1 check TESTS="$test_file" >"$scratch/run.log" 2>&1
status=$?
set -e
end=$(date +%s)
printf 'mode=%s file=%s timeout=%s elapsed=%s status=%s\n' "$mode" "$test_file" "$GOONIX_TEST_TIMEOUT" "$((end-start))" "$status" | tee "$scratch/result"

# A result must have been PRODUCED by this run.  No .trs at all means the run
# never reached the test (a failed seed, a compile error, a killed driver), and
# reporting the previous file would be a false verdict.
if test ! -f "$trs_file"; then
  echo "NO_RESULT_PRODUCED $mode $test_file: $trs_file is absent; this run produced no result" >&2
  tail -5 "$scratch/seed.log" 2>/dev/null >&2 || true
  tail -5 "$scratch/run.log" 2>/dev/null >&2 || true
  exit 2
fi
cp "$trs_file" "$scratch/result.trs"
cp "$log_file" "$scratch/result.log" 2>/dev/null || true
exit "$status"
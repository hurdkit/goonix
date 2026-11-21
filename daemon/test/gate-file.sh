#!/usr/bin/env bash
# Compile-first, seeded, one-file Guix gate runner.  The C++ timing controls
# the Haskell limit; the memory cap stays in daemon/test/lib.sh.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
cd "$root"
. daemon/test/lib.sh
mode=${1:?usage: gate-file.sh CXX|HS TEST-FILE [TIMEOUT]}
test_file=${2:?test file}
case "$test_file" in tests/*.scm|tests/*.sh) ;; *) echo 'not a Guix test file' >&2; exit 2;; esac
name=${test_file##*/}
name=${name%.*}
scratch="$root/.scratch/gate-$mode-$name"
mkdir -p "$scratch"
export GOONIX_TEST_TIMEOUT=${3:-${GOONIX_TEST_TIMEOUT:-600}}

# The top-level test-env launches this path, so select the implementation
# explicitly and restore the Haskell binary on every exit.
if test ! -e "$root/.scratch/guix-daemon-haskell"; then
  cp "$root/guix-daemon" "$root/.scratch/guix-daemon-haskell"
fi
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
elif test "$mode" = HS; then
  cp "$root/.scratch/guix-daemon-haskell" "$root/guix-daemon"
else
  echo 'mode must be CXX or HS' >&2; exit 2
fi

# Compilation is outside the measured test invocation.  Do not relink the
# selected daemon here: the generated target may be the other implementation.
# The caller has already built the Haskell daemon before selecting CXX or HS.
if test "$mode" = CXX; then cp "$root/.scratch/hs0-cxx-daemon" "$root/guix-daemon"; else cp "$root/.scratch/guix-daemon-haskell" "$root/guix-daemon"; fi
chmod -R u+rwX test-tmp 2>/dev/null || true
rm -rf test-tmp
./test-env guile --no-auto-compile /home/wrath/hurdkit/tmp-plans/goonix/tools/seed-restore.scm >"$scratch/seed.log" 2>&1
start=$(date +%s)
set +e
goonix_run_capped make -j1 check TESTS="$test_file" >"$scratch/run.log" 2>&1
status=$?
set -e
end=$(date +%s)
printf 'mode=%s file=%s timeout=%s elapsed=%s status=%s\n' "$mode" "$test_file" "$GOONIX_TEST_TIMEOUT" "$((end-start))" "$status" | tee "$scratch/result"
cp "tests/$name.trs" "$scratch/result.trs" 2>/dev/null || true
cp "tests/$name.log" "$scratch/result.log" 2>/dev/null || true
exit "$status"

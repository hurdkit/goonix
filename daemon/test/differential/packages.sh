#!/usr/bin/env bash
# HS-6 T3: one prepared input store, two real sandboxed builds, byte cmp.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
out=${1:-$root/.scratch/hs6-package-differential}
prepared=${2:-$root/.scratch/hs6-package-inputs}
case "$out" in /*) ;; *) out=$root/$out ;; esac
case "$prepared" in /*) ;; *) prepared=$root/$prepared ;; esac
if test -e "$out"; then
  if test -n "${GOONIX_HS6_REUSE_INPUTS:-}" && test -f "$out/input-paths"; then
    cp "$out/input-paths" "$out.input-paths.saved"
    if test -d "$out.metadata"; then
      cp -a "$out.metadata" "$out.metadata.saved"
    fi
  fi
  chmod -R u+rwX "$out" 2>/dev/null || true; rm -rf "$out"
fi
mkdir -p "$out"
if test -f "$out.input-paths.saved"; then mv "$out.input-paths.saved" "$out/input-paths"; fi
if test -d "$out.metadata.saved"; then mv "$out.metadata.saved" "$out/metadata"; fi
cxx=${GOONIX_CXX_DAEMON:-$root/.scratch/hs0-cxx-daemon}
hs=${GOONIX_HS_DAEMON:-$root/guix-daemon}
for daemon in "$cxx" "$hs"; do test -x "$daemon"; done
: "${GOONIX_BWRAP:?set GOONIX_BWRAP to a cached bubblewrap executable}"
: "${GOONIX_SLIRP4NETNS:?set GOONIX_SLIRP4NETNS to a cached slirp4netns executable}"
# Real configure, compiler and test-suite phases get an hour per daemon or
# preparation. The shared 2 GiB cap remains; do not remove checks for speed.
export GOONIX_TEST_TIMEOUT=${GOONIX_TEST_TIMEOUT:-3600}
export GUIX="$root/scripts/guix" GUIX_SLIRP4NETNS="$GOONIX_SLIRP4NETNS"
if test -z "${GUIX_SANDBOX:-}"; then
  export GUIX_SANDBOX="$root/guix-sandbox"
fi
: "${GUIX_SANDBOX:?set GUIX_SANDBOX to the helper built with the daemon}"
test -x "$GUIX_SANDBOX"
export GUILE_AUTO_COMPILE=0 GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES=yes
export HS6_INPUT_PATHS="$out/input-paths"
pid= scope=
cleanup() {
  status=$?
  trap - EXIT
  if test -n "$pid"; then goonix_stop_capped "$pid" "$scope"; fi
  if test "$status" -eq 0; then
    evidence=${GOONIX_HS6_EVIDENCE_DIR:-$root/.scratch/hs6-evidence-current/package-differential}
    mkdir -p "$evidence"
    for artifact in "$out"/*.out "$out"/*.err "$out"/*.log "$out"/input-paths; do
      test ! -f "$artifact" || cp -p "$artifact" "$evidence/$(basename "$artifact")"
    done
    test ! -d "$out/metadata" || cp -a "$out/metadata" "$evidence/metadata"
    chmod -R u+rwX "$out" 2>/dev/null || true
    rm -rf "$out"
  fi
  return "$status"
}
trap cleanup EXIT
with_store() {
  name=$1 daemon=$2 fixture=$3; shift 3
  export NIX_STORE_DIR=/gnu/store GUIX_DATABASE_DIRECTORY="$fixture/db"
  export GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
  export GUIX_LOG_DIRECTORY="$fixture/var/log/guix" GUIX_CONFIGURATION_DIRECTORY="$fixture/etc"
  export HS6_ROOT="$fixture"
  daemon_options="--no-substitutes"
  if test "$name" = prepare; then
    daemon_options="--substitute-urls=https://bordeaux.guix.gnu.org,https://ci.guix.gnu.org"
  fi
  # The fixture is copied from the prepared store (cp -a), which carries the
  # preparing daemon's dead var/socket.  A stale socket file makes the `test -S`
  # wait below pass at once, and the client then races the new daemon's
  # unlink/bind (errno 111 if it connects to the dead file).  Remove it first and
  # require it absent, so the wait can only see the new daemon's socket.
  rm -f "$GUIX_DAEMON_SOCKET"
  test ! -e "$GUIX_DAEMON_SOCKET"
  goonix_start_capped "$GOONIX_BWRAP" --dev-bind / / --bind "$fixture/store" /gnu/store -- "$root/pre-inst-env" "$daemon" $daemon_options --listen="$GUIX_DAEMON_SOCKET" >"$out/$name.daemon.log" 2>&1
  pid=$GOONIX_TEST_PID scope=$GOONIX_TEST_SCOPE
  for i in $(seq 1 300); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
  test -S "$GUIX_DAEMON_SOCKET"
  goonix_run_capped "$GOONIX_BWRAP" --dev-bind / / --bind "$fixture/store" /gnu/store -- "$root/pre-inst-env" "$@"
  goonix_stop_capped "$pid" "$scope"
  pid= scope=
}
paths_and_metadata() {
  if test ! -f "$out/paths.out"; then
    export HS6_MODE=paths
    with_store paths "$cxx" "$prepared" guile --no-auto-compile "$root/daemon/test/differential/package-paths.scm" >"$out/paths.out" 2>"$out/paths.err"
  fi
  # Query metadata only, never selected output NARs, before building anything.
  mkdir -p "$out/metadata"
  : >"$out/metadata/upstream-narinfos"
  while read -r line; do
    case "$line" in package=*) ;; *) continue;; esac
    output=${line#*output=}; output=${output%% *}
    member=${line#package=}; member=${member%% *}
    hash=${output#/gnu/store/}; hash=${hash%%-*}
    url="https://bordeaux.guix.gnu.org/$hash.narinfo"
    printf 'member=%s output=%s url=%s\n' "$member" "$output" "$url" | tee -a "$out/metadata/upstream-narinfos"
    curl --silent --show-error --max-time 60 -D "$out/metadata/$member.headers" -o "$out/metadata/$member.narinfo" "$url"
    printf 'response=' | tee -a "$out/metadata/upstream-narinfos"
    head -1 "$out/metadata/$member.headers" | tee -a "$out/metadata/upstream-narinfos"
    grep -E '^(StorePath|NarHash):' "$out/metadata/$member.narinfo" | tee -a "$out/metadata/upstream-narinfos"
    test "$(sed -n 's/^StorePath: //p' "$out/metadata/$member.narinfo")" = "$output"
    test -n "$(sed -n 's/^NarHash: //p' "$out/metadata/$member.narinfo")"
  done <"$out/paths.out"
}
prepare() {
  "$root/daemon/test/differential/prepare-write-fixture.sh" "$prepared"
  mkdir -p "$prepared/store" "$prepared/etc"
  paths_and_metadata
  export HS6_MODE=prepare
  with_store prepare "$cxx" "$prepared" guile --no-auto-compile "$root/daemon/test/differential/packages.scm" >"$out/prepare.out" 2>"$out/prepare.err"
  chmod -R u+rwX "$prepared/store"
}
if test -n "${GOONIX_HS6_REUSE_INPUTS:-}"; then
  test -f "$prepared/store-path" -a -f "$prepared/db/db.sqlite"
  test -f "$out/input-paths"
  for member in hello bzip2 sed; do
    test -f "$out/metadata/$member.narinfo" || {
      printf 'missing saved upstream metadata: %s\n' "$member" >&2
      exit 1
    }
  done
else prepare; fi
for name in cxx hs; do
  cp -a "$prepared" "$out/$name"
done
# Bind after fixture preparation; never replace a directory while it is bound.
export HS6_MODE=build
with_store cxx "$cxx" "$out/cxx" guile --no-auto-compile "$root/daemon/test/differential/packages.scm" >"$out/cxx.out" 2>"$out/cxx.err"
with_store hs "$hs" "$out/hs" guile --no-auto-compile "$root/daemon/test/differential/packages.scm" >"$out/hs.out" 2>"$out/hs.err"
diff -u "$out/cxx.out" "$out/hs.out"
for member in hello bzip2 sed; do
  output=$(sed -n "s/^package=$member .*output=\\([^ ]*\\).*/\\1/p" "$out/cxx.out")
  test -n "$output"
  diff -r "$out/cxx/store/${output#/gnu/store/}" "$out/hs/store/${output#/gnu/store/}"
  cxxhash=$(sed -n "s/^package=$member .*hash=\\([^ ]*\\).*/\\1/p" "$out/cxx.out")
  upstream=$(sed -n 's/^NarHash: sha256://p' "$out/metadata/$member.narinfo")
  test -n "$cxxhash" -a -n "$upstream"
  if test "$cxxhash" = "$upstream"; then
    printf 'upstream-reproducible=%s output=%s hash=%s\n' "$member" "$output" "$upstream"
  else
    printf 'upstream-different-cxx=%s output=%s cxx=%s upstream=%s\n' "$member" "$output" "$cxxhash" "$upstream"
  fi
done
printf 'HS-6 package-set differential and upstream NarHash comparisons: PASS\n'

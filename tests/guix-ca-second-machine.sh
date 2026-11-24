#!/usr/bin/env bash
# goonix: CA-8 second-machine gate.  Two INDEPENDENT stores with the SAME store
# prefix build the same small content-addressed graph from the bootstrap
# fixtures; their REALISED output paths must match (two machines that build
# independently arrive at the same names).  A non-reproducible builder (writes
# $RANDOM) must produce DIFFERENT realised names, so the gate cannot pass
# trivially.  Each machine is a private mount namespace binding a separate
# directory over a COMMON tmp store prefix (the guix-ca-files.sh pattern), with
# its own database and daemon — not a second connection to the same store, and
# no host /gnu/store touched.  Set GOONIX_SECOND_MACHINE_TMPDIR.
set -euo pipefail
if ! unshare --user --map-root-user --mount true 2>/dev/null; then
  printf 'SKIP: user/mount namespaces are unavailable\n'
  exit 77
fi

root=$(mktemp -d "${GOONIX_SECOND_MACHINE_TMPDIR:-${TMPDIR:-/tmp}}/goonix-second-machine-XXXXXX")
# The common store prefix both machines see (the daemon hashes it into every
# CA path).  A private directory is bound over it in each namespace.  It is a
# tmp path (the guix-ca-files.sh pattern), NOT /gnu/store: both machines share
# this prefix, so their CA names match, and no host store is touched.
prefix=$root/store-prefix
mkdir -p "$prefix"

completed=false
cleanup() {
  if $completed && test "${GOONIX_SECOND_MACHINE_KEEP:-}" != keep; then
    chmod -R u+w "$root" 2>/dev/null || true
    rm -rf "$root"
  else
    printf 'retained second-machine fixture: %s\n' "$root" >&2
  fi
}
trap cleanup EXIT INT TERM

# One independent machine: its own store directory (bound over $prefix), its
# own database, state and daemon.  Builds the fixture and writes realised names.
run_machine() {
  local name=$1
  local m=$root/$name
  mkdir -p "$m/store" "$m/db" "$m/etc" "$m/log"
  chmod 700 "$m/etc"
  cp tests/keys/openpgp/signing-key.sec tests/keys/openpgp/signing-key.pub "$m/etc/"
  chmod 400 "$m/etc/signing-key.sec"
  cat > "$root/$name-part.sh" <<EOF
set -euo pipefail
export NIX_STORE_DIR=$prefix GUIX_DATABASE_DIRECTORY=$m/db
export GUIX_CONFIGURATION_DIRECTORY=$m/etc GUIX_STATE_DIRECTORY=$m
export GUIX_DAEMON_SOCKET=$m/socket GUIX_LOG_DIRECTORY=$m/log
./pre-inst-env ./guix-daemon --disable-chroot --listen="\$GUIX_DAEMON_SOCKET" \
  --substitute-urls= >"$m/daemon.log" 2>&1 &
daemon_pid=\$!
trap 'kill "\$daemon_pid" 2>/dev/null || true' EXIT
for i in \$(seq 1 100); do test -S "\$GUIX_DAEMON_SOCKET" && break; sleep .1; done
./pre-inst-env guile --no-auto-compile tests/ca-second-machine-fixture.scm "$m/names.scm"
EOF
  # Bind this machine's separate store directory over the common prefix, then
  # drop back to the invoking uid so the daemon runs as the user.
  unshare --user --map-root-user --mount bash -c \
    "mount --bind '$m/store' '$prefix' && exec unshare --user --map-user=$(id -u) --map-group=$(id -g) bash '$root/$name-part.sh'"
}

run_machine machine-a
run_machine machine-b

# Read a realised name out of a machine's names.scm.
name_of() { sed -n "s/.*($2 \"\([^\"]*\)\").*/\1/p" "$root/$1/names.scm"; }

# The reproducible graph: leaf, node and top must have the SAME realised names
# on both independent machines.
for item in leaf node top; do
  a=$(name_of machine-a "$item")
  b=$(name_of machine-b "$item")
  if test -z "$a" || test -z "$b"; then
    printf 'FAIL: missing realised name for %s (a=%s b=%s)\n' "$item" "$a" "$b" >&2
    exit 1
  fi
  if test "$a" != "$b"; then
    printf 'FAIL: %s realised names differ: %s vs %s\n' "$item" "$a" "$b" >&2
    exit 1
  fi
  printf 'second-machine %s: %s (both machines agree)\n' "$item" "$a"
done

# The non-reproducible item must DIFFER (its builder writes $RANDOM).  If this
# matched, the gate would be comparing something that does not depend on the
# build — a trivial pass.
na=$(name_of machine-a nonce)
nb=$(name_of machine-b nonce)
if test -z "$na" || test -z "$nb"; then
  printf 'FAIL: missing nonce realised name (a=%s b=%s)\n' "$na" "$nb" >&2
  exit 1
fi
if test "$na" = "$nb"; then
  printf 'FAIL: non-reproducible nonce matched (%s): gate would pass trivially\n' "$na" >&2
  exit 1
fi
printf 'second-machine nonce differs as required: %s vs %s\n' "$na" "$nb"

completed=true
printf 'CA-8 second-machine gate: PASS\n'
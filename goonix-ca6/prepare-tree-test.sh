#!/usr/bin/env bash
# Test the real prepare-tree.sh without compiling Guix or starting a daemon.
# Test roots are unique, own their worktree, and never silently share the old
# /tmp/gxv-test database (goonix DECISIONS 92).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
PREPARE=$HERE/prepare-tree.sh
work=$(mktemp -d /tmp/prepare-tree-test.XXXXXX)
roots=()
cleanup() {
  local root
  for root in "${roots[@]}"; do
    chmod -R u+rwX "$root" 2>/dev/null || true
    rm -rf "$root"
  done
  rm -rf "$work"
}
trap cleanup EXIT

command -v sha256sum >/dev/null || {
  echo 'FAIL: sha256sum is required' >&2
  exit 1
}
command -v nix >/dev/null || {
  echo 'FAIL: nix is required' >&2
  exit 1
}

make_tree() {
  local tree=$1
  mkdir -p "$tree/goonix-ca6" "$tree/stub-bin"
  cp "$PREPARE" "$tree/goonix-ca6/"
  cat > "$tree/goonix-ca6/gate-lib.sh" <<'EOF'
goonix_gate_require_compiled() { return 0; }
EOF
  # The prepare script re-enters through nix develop.  This stub executes the
  # requested command in place; configure and make below do not build anything.
  cat > "$tree/stub-bin/nix" <<'EOF'
#!/usr/bin/env bash
while (($#)); do
  if [ "$1" = -c ]; then shift; exec "$@"; fi
  shift
done
exit 2
EOF
  cat > "$tree/pre-inst-env" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
  cat > "$tree/configure" <<'EOF'
#!/usr/bin/env bash
set -e
printf '%s\n' "$@" > configure.args
root=''
for arg in "$@"; do
  case "$arg" in ac_cv_guix_test_root=*) root=${arg#*=};; esac
done
test -n "$root"
printf 'S["GUIX_TEST_ROOT"]="%s"\n' "$root" > config.status
printf 'test root: %s\n' "$root" > test-env
printf '%s\n' "$root" > configured-root
EOF
  cat > "$tree/stub-bin/make" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> make.calls
EOF
  chmod +x "$tree/configure" "$tree/pre-inst-env" "$tree/stub-bin/make" "$tree/stub-bin/nix"
}

prepare() {
  local tree=$1
  tree=$(cd "$tree" && pwd -P)
  PATH="$tree/stub-bin:$PATH" IN_NIX_SHELL=1 \
    bash "$tree/goonix-ca6/prepare-tree.sh" 1 "$tree"
}

root_of() {
  local tree
  tree=$(cd "$1" && pwd -P)
  printf '/tmp/gxv-%s\n' "$(printf '%s' "$tree" | sha256sum | cut -c1-4)"
}

make_tree "$work/one"
make_tree "$work/two"
one=$(root_of "$work/one")
two=$(root_of "$work/two")
roots+=("$one" "$two")
test "$one" != "$two"
test "${#one}" -eq 13
test "${#two}" -eq 13
prepare "$work/one" > "$work/one.log"
prepare "$work/two" > "$work/two.log"
test "$(cat "$work/one/configured-root")" = "$one"
test "$(cat "$work/two/configured-root")" = "$two"
test "$(cat "$one/.owner")" = "$(cd "$work/one" && pwd -P)"
test "$(cat "$two/.owner")" = "$(cd "$work/two" && pwd -P)"
echo 'PASS: separate worktrees have equal-length distinct owned roots'

# An explicit root is still allowed, but it belongs to exactly one worktree.
explicit="$work/explicit-root"
make_tree "$work/explicit-one"
make_tree "$work/explicit-two"
PATH="$work/explicit-one/stub-bin:$PATH" IN_NIX_SHELL=1 GOONIX_TEST_ROOT="$explicit" \
  bash "$work/explicit-one/goonix-ca6/prepare-tree.sh" 1 "$work/explicit-one" \
  > "$work/explicit.log"
test "$(cat "$explicit/.owner")" = "$(cd "$work/explicit-one" && pwd -P)"
test "$(cat "$work/explicit-one/configured-root")" = "$explicit"
echo 'PASS: explicit GOONIX_TEST_ROOT is honoured and owned'

# The shared legacy root is not accepted silently, and a foreign owner refuses
# before configure or make can run.
legacy="$work/legacy-root"
mkdir -p "$legacy"
printf '%s\n' '/another/worktree' > "$legacy/.owner"
if PATH="$work/explicit-two/stub-bin:$PATH" IN_NIX_SHELL=1 GOONIX_TEST_ROOT="$legacy" \
  bash "$work/explicit-two/goonix-ca6/prepare-tree.sh" 1 "$work/explicit-two" \
  > "$work/foreign.log" 2>&1; then
  echo 'FAIL: a foreign .owner was accepted' >&2
  exit 1
fi
test ! -e "$work/explicit-two/configure.args"
grep -q 'foreign\|another worktree\|belongs' "$work/foreign.log"
echo 'PASS: foreign .owner is refused before configure or make'

printf 'S["GUIX_TEST_ROOT"]="/tmp/gxv-test"\n' > "$work/one/config.status"
prepare "$work/one" > "$work/reconfigure.log"
test "$(cat "$work/one/configured-root")" = "$one"
test "$(grep -c '^=== reconfigure: legacy shared test root ===$' "$work/reconfigure.log")" -eq 1
echo 'PASS: a legacy shared-root configuration is reconfigured'

# The actual daemon-start boundary is this small guard, tested directly.
GUARD=$HERE/../build-aux/goonix-test-root-guard.sh
guarded="$work/guarded-root"
bash "$GUARD" "$guarded" "$work/one"
test "$(cat "$guarded/.owner")" = "$work/one"
bash "$GUARD" "$guarded" "$work/one"
if bash "$GUARD" "$guarded" "$work/two" > "$work/guard.log" 2>&1; then
  echo 'FAIL: guard accepted a foreign worktree' >&2
  exit 1
fi
grep -q "$work/one" "$work/guard.log"
grep -q "$work/two" "$work/guard.log"
echo 'PASS: owner guard writes an absent owner, allows the same tree, refuses another'

echo 'PREPARE_TREE_ISOLATION_PASS'

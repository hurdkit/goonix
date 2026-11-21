#!/usr/bin/env bash
# Run each daemon and test client in its own memory-capped, time-limited scope.
goonix_run_capped() {
  local limit=${GOONIX_TEST_TIMEOUT:-300}
  if command -v systemd-run >/dev/null 2>&1 && \
      systemd-run --user --scope --quiet -p MemoryMax=2G -p MemorySwapMax=0 -- true >/dev/null 2>&1; then
    systemd-run --user --scope --quiet -p MemoryMax=2G -p MemorySwapMax=0 -- timeout "$limit" "$@"
  else
    printf 'goonix test: systemd-run unavailable; using timeout alone\n' >&2
    timeout "$limit" "$@"
  fi
}

goonix_start_capped() {
  # Use a background function, so the scope name is retained by the caller.
  local name="goonix-test-$$-${RANDOM}-${RANDOM}"
  local limit=${GOONIX_TEST_TIMEOUT:-300}
  GOONIX_TEST_SCOPE=
  if command -v systemd-run >/dev/null 2>&1 && \
      systemd-run --user --scope --quiet -p MemoryMax=2G -p MemorySwapMax=0 -- true >/dev/null 2>&1; then
    GOONIX_TEST_SCOPE="$name.scope"
    systemd-run --user --scope --quiet --unit="$name" -p MemoryMax=2G -p MemorySwapMax=0 -- timeout "$limit" "$@" &
  else
    printf 'goonix test: systemd-run unavailable; using timeout alone\n' >&2
    timeout "$limit" "$@" &
  fi
  GOONIX_TEST_PID=$!
}

goonix_stop_capped() {
  local launcher=${1:-} scope=${2:-}
  if test -n "$scope"; then
    systemctl --user stop "$scope" 2>/dev/null || true
    for i in $(seq 1 300); do
      systemctl --user is-active --quiet "$scope" || break
      sleep .01
    done
  fi
  kill "$launcher" 2>/dev/null || true
  wait "$launcher" 2>/dev/null || true
}

#!/usr/bin/env bash
# goonix: wait until the daemon that test-env started listens on SOCKET.
#
# usage: goonix-wait-socket.sh SOCKET PID
#
# test-env starts guix-daemon in the background and then runs its command.
# A command that connects at once, such as a nested
# `./test-env ./pre-inst-env guile -c '(open-connection)'`, can otherwise
# reach the socket before the daemon has created it and fail with ENOENT.
#
# Exits 0 once SOCKET exists.  Exits 1 with a message naming SOCKET when the
# daemon PID has exited first, or when GOONIX_SOCKET_WAIT_TIMEOUT seconds
# (default 60) pass without the socket.
set -euo pipefail
socket=$1 pid=$2
timeout=${GOONIX_SOCKET_WAIT_TIMEOUT:-60}
case "$timeout" in ''|*[!0-9]*)
  echo "goonix-wait-socket: GOONIX_SOCKET_WAIT_TIMEOUT must be a number of seconds, not '$timeout'" >&2
  exit 1
esac

# The daemon is a child of test-env, which does not reap it while this script
# runs: a daemon that died is a zombie, and 'kill -0' still succeeds on it.
alive() {
  kill -0 "$pid" 2>/dev/null || return 1
  local stat
  if stat=$(cat "/proc/$pid/stat" 2>/dev/null); then
    stat=${stat##*) }
    case "${stat%% *}" in Z|X) return 1 ;; esac
  fi
  return 0
}

deadline=$((SECONDS + timeout))
until test -S "$socket"; do
  if ! alive; then
    echo "goonix-wait-socket: the daemon (PID $pid) exited before its socket $socket appeared" >&2
    exit 1
  fi
  if ((SECONDS >= deadline)); then
    echo "goonix-wait-socket: no socket at $socket after ${timeout}s; the daemon (PID $pid) is still running" >&2
    exit 1
  fi
  sleep 0.1
done

#!/bin/sh
# goonix: test-env runs its command only once the daemon's socket exists.
#
# A scratch copy of this tree's test-env starts a wrapper instead of
# guix-daemon.  The wrapper sleeps before it runs the real daemon, so the
# socket appears late.  The command records whether the socket existed when
# it started, then connects the way a nested `./test-env ./pre-inst-env guile
# -c '(open-connection)'` does.  The tree's own daemon and test-env are not
# changed.
set -eu

test -x ./test-env || { echo 'run from the build directory' >&2; exit 1; }
test -x ./guix-daemon || { echo 'SKIP: the daemon is not built'; exit 77; }
unset GUIX_DAEMON_SOCKET

work=$(mktemp -d "${TMPDIR:-/tmp}/goonix-test-env-socket-XXXXXX")
sleeper=
cleanup() {
  test -z "$sleeper" || kill "$sleeper" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# scratch_test_env DAEMON OUT: a copy of test-env that starts DAEMON instead
# of guix-daemon.
scratch_test_env() {
  sed "s#\"[^\"]*/guix-daemon\"#\"$1\"#g" ./test-env > "$2"
  chmod 755 "$2"
  test "$(grep -cF "\"$1\"" "$2")" -ge 2
  if grep -qF '/guix-daemon"' "$2"; then
    echo "$2 still starts guix-daemon" >&2
    return 1
  fi
}

daemon=$(pwd -P)/guix-daemon
cat > "$work/late-daemon" <<EOF
#!/bin/sh
sleep 2
exec "$daemon" "\$@"
EOF
cat > "$work/dead-daemon" <<'EOF'
#!/bin/sh
exit 3
EOF
chmod 755 "$work/late-daemon" "$work/dead-daemon"

cat > "$work/client" <<EOF
#!/bin/sh
: > "$work/client-ran"
if test -S "\$GUIX_STATE_DIRECTORY/daemon-socket/socket"; then
  echo 'socket at start: yes'
else
  echo 'socket at start: no'
fi
exec guile --no-auto-compile -c '(use-modules (guix store))
(close-connection (open-connection))
(display "connected\n")'
EOF
chmod 755 "$work/client"

# A daemon whose socket appears late: the command starts after it and connects.
scratch_test_env "$work/late-daemon" "$work/test-env-late"
status=0
"$work/test-env-late" "$work/client" > "$work/late.log" 2>&1 || status=$?
cat "$work/late.log"
grep -qx 'socket at start: yes' "$work/late.log"
grep -qx 'connected' "$work/late.log"
test "$status" -eq 0

# A daemon that dies before its socket exists: test-env fails, naming it, and
# does not run the command.
rm -f "$work/client-ran"
scratch_test_env "$work/dead-daemon" "$work/test-env-dead"
status=0
"$work/test-env-dead" "$work/client" > "$work/dead.log" 2>&1 || status=$?
cat "$work/dead.log"
test "$status" -ne 0
grep -q 'exited before its socket' "$work/dead.log"
test ! -e "$work/client-ran"

# A daemon that is alive but never listens: the wait ends at its timeout.
wait_socket=$(sed -n 's#^ *"\([^"]*/goonix-wait-socket\.sh\)".*#\1#p' ./test-env)
test -x "$wait_socket"
sleep 60 & sleeper=$!
status=0
GOONIX_SOCKET_WAIT_TIMEOUT=1 "$wait_socket" "$work/no-socket" "$sleeper" \
  > "$work/timeout.log" 2>&1 || status=$?
cat "$work/timeout.log"
test "$status" -ne 0
grep -q "no socket at $work/no-socket" "$work/timeout.log"
kill "$sleeper"
sleeper=

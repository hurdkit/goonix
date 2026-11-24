#!/usr/bin/env bash
# goonix: asynchronous record requests must not occupy a build slot or block
# the worker on a dead/silent helper.  Substitutes remain enabled throughout.
set -euo pipefail
root=$(mktemp -d "${TMPDIR:-/tmp}/goonix-async-XXXXXX")
store=${root}-store
socket=$root/daemon.socket
port=${GOONIX_ASYNC_PORT:-6827}
server_pid=
completed=false
cleanup() {
  if test -n "$server_pid"; then kill "$server_pid" 2>/dev/null || true; fi
  if test -n "${daemon_pid:-}"; then kill "$daemon_pid" 2>/dev/null || true; fi
  wait 2>/dev/null || true
  if $completed; then rm -rf "$root" "$store"; else printf 'retained async fixture: %s\n' "$root" >&2; fi
}
trap cleanup EXIT INT TERM
mkdir -p "$store" "$root/db" "$root/etc" "$root/state" "$root/log"
chmod 700 "$root/etc"
cp tests/keys/openpgp/signing-key.sec tests/keys/openpgp/signing-key.pub "$root/etc/"
chmod 400 "$root/etc/signing-key.sec"
cat > "$root/shell" <<'EOF'
#!/bin/sh
exec /bin/sh "$@"
EOF
chmod 755 "$root/shell"
export NIX_STORE_DIR=$store GUIX_DATABASE_DIRECTORY=$root/db
export GUIX_CONFIGURATION_DIRECTORY=$root/etc GUIX_STATE_DIRECTORY=$root/state
export GUIX_DAEMON_SOCKET=$socket GUIX_LOG_DIRECTORY=$root/log
export GOONIX_SHELL_SOURCE=$root/shell GOONIX_ASYNC_ROOT=$root
export GOONIX_ASYNC_URL=http://127.0.0.1:$port
export _NIX_OPTIONS=build-graph-timeout=10

# Serve each connection independently.  Ordinary narinfo requests get an
# immediate 404; the record request is deliberately left open forever.
: > "$root/events"
perl -MIO::Socket::INET -e '
  my $s=IO::Socket::INET->new(LocalAddr=>"127.0.0.1",LocalPort=>'"$port"',Listen=>20,ReuseAddr=>1) or die $!;
  open my $f,">>","'$root'/events" or die $!;
  select((select($f),$|=1)[0]);
  while (my $c=$s->accept) {
    my $pid=fork(); die "fork: $!" unless defined $pid;
    if ($pid==0) {
      sysread($c,my $request,4096);
      if ($request =~ m{GET /goonix/records/([^ ]+)}) {
        print $f "records accepted $1\n";
        while (sysread($c,my $b,4096)) { }
        print $f "records closed $1\n";
      } else {
        print $c "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        close $c;
        print $f "narinfo 404\n";
      }
      exit 0;
    }
    close $c;
  }
' >"$root/server.log" 2>&1 & server_pid=$!

export GOONIX_ASYNC_GUIX=$root/guix
export GUIX=$GOONIX_ASYNC_GUIX
while IFS= read -r line; do export "$line"; done < <(
  ./pre-inst-env perl -MEnv -e 'for $v (qw(GUILE_LOAD_PATH GUILE_LOAD_COMPILED_PATH GOONIX_DEEP_SCAN_HELPER)) { print "$v=$ENV{$v}\n" }'
)
GUIX=$GOONIX_ASYNC_GUIX
export GUIX
export GOONIX_REAL_GUIX=$PWD/scripts/guix
export GOONIX_ASYNC_HELPER_PID=$root/helper.pid
cat > "$GUIX" <<'EOF'
#!/bin/sh
# First exercise a real silent cache with the ordinary helper.
exec "$GOONIX_REAL_GUIX" "$@"
EOF
chmod 755 "$GUIX"
./guix-daemon --disable-chroot --listen="$socket" \
  --substitute-urls="http://127.0.0.1:$port" --max-jobs=1 \
  >"$root/silent-daemon.log" 2>&1 & daemon_pid=$!
for i in $(seq 1 100); do test -S "$socket" && break; sleep .05; done
timeout 60 ./pre-inst-env guile --no-auto-compile tests/ca-async-fixture.scm silent "$root/silent-fixture.scm" \
  >"$root/client.log" 2>&1
# The client receives the daemon's marked build-start event in its protocol
# stream; the graph connection remains open across that event.
name=$(grep '^records accepted ' "$root/events" | head -1 | sed 's/^records accepted //')
test -n "$name"
builder_line=$(grep -n '^builder$' "$root/events" | head -1 | cut -d: -f1)
accepted_line=$(grep -n -F "records accepted $name" "$root/events" | head -1 | cut -d: -f1)
closed_line=$(grep -n -F "records closed $name" "$root/events" | head -1 | cut -d: -f1)
test "$accepted_line" -lt "$builder_line"
test "$builder_line" -lt "$closed_line"
grep -F '@ build-started ' "$root/client.log" | grep -F 'async-other.drv'
kill "$daemon_pid"; wait "$daemon_pid" 2>/dev/null || true

# A helper that never answers and ignores its own timeout must be ended by
# the worker's deadline.  Use a fresh store and socket for this case.
rm -rf "$store" "$root/db" "$root/state" "$root/log"
mkdir -p "$store" "$root/db" "$root/state" "$root/log"
cat > "$GUIX" <<'EOF'
#!/bin/sh
# Only the graph helper ignores its own timeout.  All other daemon commands
# use the real Guix, including the ordinary substitute query agent.
if test "$1 $2" = "substitute --goonix-graph"; then
  printf '%s\n' "$$" > "$GOONIX_ASYNC_HELPER_PID"
  while :; do sleep 60; done
fi
exec "$GOONIX_REAL_GUIX" "$@"
EOF
chmod 755 "$GUIX"
./guix-daemon --disable-chroot --listen="$socket" \
  --substitute-urls="http://127.0.0.1:$port" --max-jobs=1 \
  >"$root/daemon.log" 2>&1 & daemon_pid=$!
for i in $(seq 1 100); do test -S "$socket" && break; sleep .05; done
timeout 60 ./pre-inst-env guile --no-auto-compile tests/ca-async-fixture.scm dead "$root/fixture.scm" >"$root/dead-client.log" 2>&1
# The helper is a separate process; the daemon itself may be a terminated
# zombie whose PID still accepts kill(2).
helper=$(cat "$GOONIX_ASYNC_HELPER_PID")
if kill -0 "$helper" 2>/dev/null; then
  printf 'graph helper survived the worker deadline: %s\n' "$helper" >&2
  exit 1
fi
# The sleeping helper never reaches the cache; its PID is the deadline proof.
test -s "$GOONIX_ASYNC_HELPER_PID"
grep -F 'reached its graph cache deadline' "$root/dead-client.log"
kill "$daemon_pid"; wait "$daemon_pid" 2>/dev/null || true

completed=true
printf 'asynchronous graph deadline gate: PASS\n'

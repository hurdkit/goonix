#!/usr/bin/env bash
# HS-11 graph-agent lifecycle: prompt replies settle immediately, silent helpers
# die at the graph deadline, and no helper or records connection leaks.
set -euo pipefail
root=$(mktemp -d "${TMPDIR:-/tmp}/goonix-async-lifecycle-XXXXXX")
store=${root}-store
socket=$root/daemon.socket
port=${GOONIX_ASYNC_LIFECYCLE_PORT:-6831}
server_pid= daemon_pid=
cleanup() {
  if test -n "$server_pid"; then kill "$server_pid" 2>/dev/null || true; fi
  if test -n "$daemon_pid"; then kill "$daemon_pid" 2>/dev/null || true; fi
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM
mkdir -p "$store" "$root/db" "$root/etc" "$root/state" "$root/log"
chmod 700 "$root/etc"
cp tests/keys/openpgp/signing-key.sec tests/keys/openpgp/signing-key.pub "$root/etc/"
chmod 400 "$root/etc/signing-key.sec"
printf '#!/bin/sh\nexec /bin/sh "$@"\n' > "$root/shell"
chmod 755 "$root/shell"
export NIX_STORE_DIR=$store GUIX_DATABASE_DIRECTORY=$root/db
export GUIX_CONFIGURATION_DIRECTORY=$root/etc GUIX_STATE_DIRECTORY=$root/state
export GUIX_DAEMON_SOCKET=$socket GUIX_LOG_DIRECTORY=$root/log
export GOONIX_SHELL_SOURCE=$root/shell GOONIX_ASYNC_ROOT=$root
export GOONIX_ASYNC_URL=http://127.0.0.1:$port
export _NIX_OPTIONS=build-graph-timeout=30

# Every records request is answered immediately with an empty graph.  The
# response and connection close are logged independently.
: > "$root/events"
perl -MIO::Socket::INET -e '
  my $s=IO::Socket::INET->new(LocalAddr=>"127.0.0.1",LocalPort=>'"$port"',Listen=>20,ReuseAddr=>1) or die $!;
  open my $f,">>","'$root'/events" or die $!;
  select((select($f),$|=1)[0]);
  $SIG{CHLD} = "IGNORE";
  while (my $c=$s->accept) {
    my $pid=fork(); die "fork: $!" unless defined $pid;
    if ($pid==0) {
      sysread($c,my $request,4096);
      if ($request =~ m{GET /goonix/records/([^ ]+)}) {
        print $f "records accepted $1\n";
        print $c "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        close $c;
        print $f "records closed $1\n";
      } else {
        print $c "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        close $c;
      }
      exit 0;
    }
    close $c;
  }
' >"$root/server.log" 2>&1 & server_pid=$!

export GUIX=$root/guix GOONIX_REAL_GUIX=$PWD/scripts/guix
while IFS= read -r line; do export "$line"; done < <(
  ./pre-inst-env perl -MEnv -e 'for $v (qw(GUILE_LOAD_PATH GUILE_LOAD_COMPILED_PATH GOONIX_DEEP_SCAN_HELPER)) { print "$v=$ENV{$v}\n" }'
)
export GUIX=$root/guix GOONIX_ASYNC_HELPER_PID=$root/helper.pid
cat > "$GUIX" <<'EOF'
#!/bin/sh
exec "$GOONIX_REAL_GUIX" "$@"
EOF
chmod 755 "$GUIX"
./guix-daemon --disable-chroot --listen="$socket" \
  --substitute-urls="http://127.0.0.1:$port" --max-jobs=1 \
  >"$root/daemon.log" 2>&1 & daemon_pid=$!
for i in $(seq 1 100); do test -S "$socket" && break; sleep .05; done
start=$(date +%s)
timeout 25 ./pre-inst-env guile --no-auto-compile tests/ca-async-fixture.scm silent "$root/fixture.scm" \
  >"$root/client.log" 2>&1
elapsed=$(( $(date +%s) - start ))
# With a 30 s deadline, a prompt empty answer must settle well before it.
test "$elapsed" -lt 20
kill "$daemon_pid"; wait "$daemon_pid" 2>/dev/null || true
daemon_pid=
grep -F 'records accepted ' "$root/events"
grep -F 'records closed ' "$root/events"
# No graph helper of this daemon survives the completed build.
if ps -eo pid,args | grep '[s]ubstitute --goonix-graph' | grep -F "$root/guix"; then
  echo 'graph helper survived the completed build' >&2
  exit 1
fi
printf 'graph prompt-answer lifecycle: PASS (%ss, deadline 30s)\n' "$elapsed"

# Two caches: the first helper says "no graph" immediately; the query must
# reach the second one (C++ retry, build-goonix.inc:323-332).
kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=
rm -rf "$store" "$root/db" "$root/state" "$root/log"
mkdir -p "$store" "$root/db" "$root/state" "$root/log"
: > "$root/events"
perl -MIO::Socket::INET -e '
  my $s=IO::Socket::INET->new(LocalAddr=>"127.0.0.1",LocalPort=>'"$port"',Listen=>20,ReuseAddr=>1) or die $!;
  open my $f,">>","'$root'/events" or die $!;
  select((select($f),$|=1)[0]);
  $SIG{CHLD} = "IGNORE";
  while (my $c=$s->accept) {
    my $pid=fork(); die "fork: $!" unless defined $pid;
    if ($pid==0) {
      sysread($c,my $request,4096);
      if ($request =~ m{GET /goonix/records/([^ ]+)}) {
        print $f "second-cache records $1\n";
      }
      # Ordinary substitution also asks for narinfos.  A responseless close
      # makes the client reconnect immediately; answer every request instead.
      print $c "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
      close $c;
      exit 0;
    }
    close $c;
  }
' >"$root/server.log" 2>&1 & server_pid=$!
export GOONIX_ASYNC_URL=http://127.0.0.1:$port/first
export GOONIX_ASYNC_URL_SECOND=http://127.0.0.1:$port/second
cat > "$GUIX" <<'EOF'
#!/bin/sh
if test "$1 $2" = "substitute --goonix-graph"; then
  # Both daemons read graph replies on fd 4; stdout/stderr are the log pipe.
  read -r request
  printf '%s\n' "$request" >> "$GOONIX_ASYNC_ROOT/helper-calls"
  if test ! -e "$GOONIX_ASYNC_ROOT/first-graph"; then
    : > "$GOONIX_ASYNC_ROOT/first-graph"
    printf 'goonix-records 1\n0\n0\n' >&4
    exit 0
  fi
  printf 'goonix-records 1\n0\n1\nfirst\nout\npath\n' >&4
  exit 0
fi
exec "$GOONIX_REAL_GUIX" "$@"
EOF
chmod 755 "$GUIX"
./guix-daemon --disable-chroot --listen="$socket" \
  --substitute-urls="http://127.0.0.1:$port/first http://127.0.0.1:$port/second" --max-jobs=1 \
  >"$root/daemon-retry.log" 2>&1 & daemon_pid=$!
for i in $(seq 1 100); do test -S "$socket" && break; sleep .05; done
# Ignore graph invalidation while writing the build fixtures; the retry
# assertions cover only the derivation's graph lookup.
: > "$root/helper-calls"
timeout 25 ./pre-inst-env guile --no-auto-compile tests/ca-async-fixture.scm silent "$root/retry-fixture.scm" \
  >"$root/retry-client.log" 2>&1
kill "$daemon_pid"; wait "$daemon_pid" 2>/dev/null || true
daemon_pid=
test -e "$root/first-graph"
test "$(wc -l < "$root/helper-calls")" -eq 2
test "$(sed -n '1s/^.* //p' "$root/helper-calls")" = "http://127.0.0.1:$port/first"
test "$(sed -n '2s/^.* //p' "$root/helper-calls")" = "http://127.0.0.1:$port/second"
printf 'graph no-graph retry to second cache: PASS\n'

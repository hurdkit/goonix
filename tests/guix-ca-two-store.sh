#!/usr/bin/env bash
# goonix: CA-5 two-store graph sharing gate.  Set GOONIX_TWO_STORE_PORT to
# avoid a publisher port collision; default 6791.
set -euo pipefail
if ! unshare --user --map-root-user --mount true 2>/dev/null; then
  printf 'SKIP: user/mount namespaces are unavailable\n'
  exit 77
fi

root=$(mktemp -d "${GOONIX_TWO_STORE_TMPDIR:-${TMPDIR:-/tmp}}/goonix-two-store-XXXXXX")
server=$root/server
client=$root/client
store=${GOONIX_TWO_STORE_STORE:-${root}-store}
client_store=$client/store
port=${GOONIX_TWO_STORE_PORT:-6791}
url=http://127.0.0.1:$port
mkdir -p "$store" "$client_store" "$server/db" "$server/etc" "$server/log" \
         "$client/db" "$client/etc" "$client/log"
chmod 700 "$server/etc" "$client/etc"
for side in "$server/etc" "$client/etc"; do
  cp tests/keys/openpgp/signing-key.sec tests/keys/openpgp/signing-key.pub "$side/"
  chmod 400 "$side/signing-key.sec"
done
{
  printf '(acl (entry '
  cat tests/keys/openpgp/signing-key.pub
  printf ' (tag (guix import))))\n'
} > "$client/etc/acl"
printf '#!/bin/sh\nexec /bin/sh "$@"\n' > "$root/shell"
chmod 755 "$root/shell"

server_pid= publisher_pid= client_pid= bad_pid= silent_pid= empty_pid= concurrent_pid=
completed=false
cleanup() {
  test ! -d "$root" || : > "$root/hold-released"
  for pid in $concurrent_pid $silent_pid $bad_pid $empty_pid $publisher_pid $client_pid $server_pid; do
    if test -n "$pid"; then kill "$pid" 2>/dev/null || true; fi
  done
  wait 2>/dev/null || true
  if $completed && test "${GOONIX_TWO_STORE_KEEP:-}" != keep; then
    chmod -R u+w "$root" "$store" 2>/dev/null || true
    rm -rf "$root" "$store"
  else
    printf 'retained two-store fixture: %s\n' "$root" >&2
  fi
}
trap cleanup EXIT INT TERM

export NIX_STORE_DIR=$store GUIX_DATABASE_DIRECTORY=$server/db
export GUIX_CONFIGURATION_DIRECTORY=$server/etc GUIX_STATE_DIRECTORY=$server
export GUIX_DAEMON_SOCKET=$server/socket GUIX_LOG_DIRECTORY=$server/log
export GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES=no
export GOONIX_SHELL_SOURCE=$root/shell
export GOONIX_BUILD_MARKER=$root/server-build-marker
export GOONIX_SLEEP_SOURCE=$(command -v sleep)
export GOONIX_ASYNC_ROOT=$root
./pre-inst-env ./guix-daemon --disable-chroot --listen="$server/socket" \
  --substitute-urls= >"$root/server.log" 2>&1 & server_pid=$!
for i in $(seq 1 100); do test -S "$server/socket" && break; sleep .1; done
./pre-inst-env guile --no-auto-compile tests/ca-two-store-fixture.scm \
  server "$root/fixture.scm"

NIX_STORE_DIR=$store GUIX_DATABASE_DIRECTORY=$server/db \
GUIX_CONFIGURATION_DIRECTORY=$server/etc GUIX_STATE_DIRECTORY=$server \
GUIX_DAEMON_SOCKET=$server/socket \
  ./pre-inst-env guix publish --listen=127.0.0.1 --port="$port" -C0 \
  >"$root/publish.log" 2>&1 & publisher_pid=$!
for i in $(seq 1 100); do
  if curl -fsS "$url/nix-cache-info" >/dev/null; then break; fi
  sleep .1
done

cat > "$root/client-part.sh" <<EOF
set -euo pipefail
export NIX_STORE_DIR=$store GUIX_DATABASE_DIRECTORY=$client/db
export GUIX_CONFIGURATION_DIRECTORY=$client/etc GUIX_STATE_DIRECTORY=$client
export GUIX_DAEMON_SOCKET=$client/socket GUIX_LOG_DIRECTORY=$client/log
export GOONIX_GRAPH_HELPER_LOG=$root/graph-helper.log
export GOONIX_SERVER_URL=$url GOONIX_SERVER_STORE=$store
export GOONIX_SHELL_SOURCE=$root/shell GOONIX_BUILD_MARKER=$root/server-build-marker
./pre-inst-env ./guix-daemon --disable-chroot --listen="\$GUIX_DAEMON_SOCKET" \
  --substitute-urls="\$GOONIX_SERVER_URL" >"$root/client-daemon.log" 2>&1 &
daemon_pid=\$!
trap 'kill "\$daemon_pid" 2>/dev/null || true' EXIT
for i in \$(seq 1 100); do test -S "\$GUIX_DAEMON_SOCKET" && break; sleep .1; done
./pre-inst-env guile --no-auto-compile tests/ca-two-store-fixture.scm \
  plain "$root/fixture.scm"
EOF
unshare --user --map-root-user --mount bash -c \
  "mount --bind '$client_store' '$store' && exec unshare --user --map-user=$(id -u) --map-group=$(id -g) bash '$root/client-part.sh'" &
client_pid=$!
wait "$client_pid"

graph_count=$(grep -c '^GET /goonix/records/' "$root/publish.log" || true)
# Two top-level builds: one later derivation and one dependent graph.
test "$graph_count" -eq 2
grep -F "GET /goonix/records/$(sed -n 's/.*(later "\([^"]*\)").*/\1/p' "$root/fixture.scm" | xargs basename)" "$root/publish.log"
grep -F "GET /goonix/records/$(sed -n 's/.*(dependent "\([^"]*\)").*/\1/p' "$root/fixture.scm" | xargs basename)" "$root/publish.log"
test "$(grep -c '^GET /nar/' "$root/publish.log" || true)" -ge 2
cp "$root/publish.log" "$root/plain-publish.log"

# A local result of the same non-reproducible input takes precedence.  The
# dependent must be built against it, not fetched against the server's result.
mkdir -p "$client/two-store" "$client/two-db" "$client/two-state" "$client/two-log"
cat > "$root/two-result-part.sh" <<EOF
set -euo pipefail
export NIX_STORE_DIR=$store GUIX_DATABASE_DIRECTORY=$client/two-db
export GUIX_CONFIGURATION_DIRECTORY=$client/etc GUIX_STATE_DIRECTORY=$client/two-state
export GUIX_DAEMON_SOCKET=$client/two.socket GUIX_LOG_DIRECTORY=$client/two-log
export GOONIX_SERVER_URL=$url GOONIX_SERVER_STORE=$store
export GOONIX_SHELL_SOURCE=$root/shell GOONIX_BUILD_MARKER=$root/server-build-marker
./pre-inst-env ./guix-daemon --disable-chroot --listen="\$GUIX_DAEMON_SOCKET" \
  --substitute-urls="\$GOONIX_SERVER_URL" >"$root/two-daemon.log" 2>&1 &
pid=\$!
trap 'kill "\$pid" 2>/dev/null || true' EXIT
for i in \$(seq 1 100); do test -S "\$GUIX_DAEMON_SOCKET" && break; sleep .1; done
./pre-inst-env guile --no-auto-compile tests/ca-two-store-fixture.scm \
  two-result "$root/fixture.scm"
EOF
before=$(grep -c '^GET /goonix/records/' "$root/publish.log" || true)
unshare --user --map-root-user --mount bash -c \
  "mount --bind '$client/two-store' '$store' && exec unshare --user --map-user=$(id -u) --map-group=$(id -g) bash '$root/two-result-part.sh'"
after=$(grep -c '^GET /goonix/records/' "$root/publish.log" || true)
# Only the first input lookup needs the network.  The locally built input
# and dependent are already named by the imported graph.
test $((after-before)) -eq 1

# Two top-level graphs in one request share one coherent input.
mkdir -p "$client/concurrent-store"
sed -e 's/two-db/concurrent-db/g' -e 's/two-state/concurrent-state/g' \
    -e 's/two-log/concurrent-log/g' -e 's/two.socket/concurrent.socket/g' \
    -e 's/two-result/concurrent/g' -e 's/two-daemon/concurrent-daemon/g' "$root/two-result-part.sh" > "$root/concurrent-part.sh"
before=$(grep -c '^GET /goonix/records/' "$root/publish.log" || true)
publisher_lines=$(wc -l < "$root/publish.log")
export GOONIX_ASYNC_ROOT=$root
: > "$root/hold-enabled"
sed -i 's#--disable-chroot#--disable-chroot --debug#' "$root/concurrent-part.sh"
sed -i "s#concurrent \"$root/fixture.scm\"#concurrent \"$root/fixture.scm\" >\"$root/concurrent-client.log\" 2>\&1#" "$root/concurrent-part.sh"
unshare --user --map-root-user --mount bash -c \
  "mount --bind '$client/concurrent-store' '$store' && exec unshare --user --map-user=$(id -u) --map-group=$(id -g) bash '$root/concurrent-part.sh'" >"$root/concurrent-wrapper.log" 2>&1 &
concurrent_pid=$!
for i in $(seq 1 100); do
  if tail -n "+$((publisher_lines + 1))" "$root/publish.log" | grep -qE 'GET /goonix/records/.*-two-store-dependent.drv'; then break; fi
  if ! kill -0 "$concurrent_pid" 2>/dev/null; then cat "$root/concurrent-client.log"; exit 1; fi
  sleep .1
done
grep -E 'GET /goonix/records/.*-two-store-dependent.drv' "$root/publish.log"
for i in $(seq 1 600); do
  if grep -q 'two-store-dependent.drv.: answer imported' "$root/concurrent-client.log" 2>/dev/null; then break; fi
  if ! kill -0 "$concurrent_pid" 2>/dev/null; then cat "$root/concurrent-client.log"; exit 1; fi
  sleep .1
done
grep -F 'answer imported' "$root/concurrent-client.log"
builder_line=$(grep -nE '@ build-started .*-two-store-input.drv' "$root/concurrent-client.log" | sed -n '1s/:.*//p')
import_line=$(grep -nE 'two-store-dependent.drv.: answer imported' "$root/concurrent-client.log" | sed -n '1s/:.*//p')
test -n "$builder_line" && test -n "$import_line" && test "$builder_line" -lt "$import_line"
: > "$root/hold-released"
wait "$concurrent_pid"
concurrent_pid=
grep -F 'dropping choice' "$root/concurrent-client.log" | grep -F 'two-store-dependent'
after=$(grep -c '^GET /goonix/records/' "$root/publish.log" || true)
test $((after-before)) -ge 2
for drv in two-store-dependent two-store-local-dependent; do
  grep -E "^GET /goonix/records/.*-$drv.drv" "$root/publish.log"
done

# An unauthorized graph is refused by the daemon; the next cache is asked.
retry_port=$((port + 100))
empty_port=$((port + 101))
: > "$root/empty-publish.log"
perl -MIO::Socket::INET -e '
  my $s=IO::Socket::INET->new(LocalAddr=>"127.0.0.1",LocalPort=>'"$empty_port"',Listen=>20,ReuseAddr=>1) or die $!;
  open my $f,">>","'$root'/empty-publish.log" or die $!;
  select((select($f),$|=1)[0]);
  while (my $c=$s->accept) {
    my $pid=fork(); die "fork: $!" unless defined $pid;
    if ($pid==0) {
      sysread($c,my $request,4096);
      print $f ($request =~ m{^([^ ]+ [^ ]+)}) ? "$1\n" : "request\n";
      print $c "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
      close $c; exit 0;
    }
    close $c;
  }
' >"$root/empty-server.log" 2>&1 & empty_pid=$!
for i in $(seq 1 100); do
  if timeout 1 bash -c "</dev/tcp/127.0.0.1/$empty_port" 2>/dev/null; then break; fi
  sleep .1
done
bad=$root/bad-cache
mkdir -p "$bad/db" "$bad/etc" "$bad/log"
mkdir -p "$store"
NIX_STORE_DIR=$store GUIX_CONFIGURATION_DIRECTORY=$bad/etc \
  ./pre-inst-env guile --no-auto-compile -c '
(use-modules (gcrypt pk-crypto) (guix pki) (rnrs io ports))
(let* ((pair (generate-key (string->canonical-sexp "(genkey (ecc (curve Ed25519)))")))
       (private (find-sexp-token pair (quote private-key)))
       (public (find-sexp-token pair (quote public-key))))
  (call-with-output-file (string-append (getenv "GUIX_CONFIGURATION_DIRECTORY") "/signing-key.sec")
    (lambda (p) (display (canonical-sexp->string private) p)))
  (call-with-output-file (string-append (getenv "GUIX_CONFIGURATION_DIRECTORY") "/signing-key.pub")
    (lambda (p) (display (canonical-sexp->string public) p))))'
NIX_STORE_DIR=$store GUIX_DATABASE_DIRECTORY=$server/db \
GUIX_CONFIGURATION_DIRECTORY=$bad/etc GUIX_STATE_DIRECTORY=$server \
GUIX_DAEMON_SOCKET=$server/socket GOONIX_BAD_PORT=$retry_port \
  ./pre-inst-env guile --no-auto-compile tests/ca-untrusted-cache.scm \
  >"$root/bad-publish.log" 2>&1 & bad_pid=$!
for i in $(seq 1 100); do
  if timeout 1 bash -c "</dev/tcp/127.0.0.1/$retry_port" 2>/dev/null; then break; fi
  sleep .1
done
for mode in bad none silent; do
  mkdir -p "$client/retry-$mode-store"
  first="http://127.0.0.1:$retry_port"
  if test "$mode" = none; then
    first="http://127.0.0.1:$empty_port"
  elif test "$mode" = silent; then
    silent_port=$((port + 102))
    perl -MIO::Socket::INET -e '
      my $s=IO::Socket::INET->new(LocalAddr=>"127.0.0.1",LocalPort=>'"$silent_port"',Listen=>20,ReuseAddr=>1) or die $!;
      open my $f,">","'$root'/silent-publish.log" or die $!;
      select((select($f),$|=1)[0]);
      while (my $c=$s->accept) {
        my $pid=fork(); die "fork: $!" unless defined $pid;
        if ($pid==0) {
          sysread($c,my $request,4096);
          if ($request =~ m{GET /goonix/records/([^ ]+)}) { print $f "GET /goonix/records/$1\n"; while (sysread($c,my $b,4096)) {} }
          else { print $c "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"; }
          close $c; exit 0;
        }
        close $c;
      }
    ' & silent_pid=$!
    first="http://127.0.0.1:$silent_port"
  fi
  sed -e "s/two-db/retry-$mode-db/g" -e "s/two-state/retry-$mode-state/g" \
      -e "s/two-log/retry-$mode-log/g" -e "s/two.socket/retry-$mode.socket/g" \
      -e "s/two-daemon/retry-$mode-daemon/g" \
      -e 's/two-result/retry/g' "$root/two-result-part.sh" > "$root/retry-$mode-part.sh"
  sed -i "/^set -euo pipefail$/a\\
export GOONIX_RETRY_URLS='$first $url'\n\\
export _NIX_OPTIONS=build-graph-timeout=3" "$root/retry-$mode-part.sh"
  sed -i '/--substitute-urls=/s#--substitute-urls="[^"]*"#--substitute-urls="'"$first $url"'"#' "$root/retry-$mode-part.sh"
  printf 'part: retry-%s\n' "$mode"
  publisher_before=$(grep -c '^GET /goonix/records/' "$root/publish.log" || true)
  unshare --user --map-root-user --mount bash -c \
    "mount --bind '$client/retry-$mode-store' '$store' && exec unshare --user --map-user=$(id -u) --map-group=$(id -g) bash '$root/retry-$mode-part.sh'"
  if test "$mode" = silent; then
    test "$(grep -c '^GET /goonix/records/' "$root/silent-publish.log")" -eq 1
    kill "$silent_pid"; wait "$silent_pid" 2>/dev/null || true
  elif test "$mode" = none; then
    test "$(grep -c '^GET /goonix/records/' "$root/empty-publish.log")" -eq 1
    publisher_after=$(grep -c '^GET /goonix/records/' "$root/publish.log" || true)
    test "$publisher_after" -eq "$((publisher_before + 1))"
    grep '^GET /nar/.*-two-store-earlier' "$root/publish.log" | tail -1
  else
    test "$(grep -c '^GET /goonix/records/' "$root/bad-publish.log")" -eq 1
  fi
done
# An unauthorized-only graph is reported and falls back to a local build.
mkdir -p "$client/unauthorized-store"
sed -e 's/two-db/unauthorized-db/g' -e 's/two-state/unauthorized-state/g' \
    -e 's/two-log/unauthorized-log/g' -e 's/two.socket/unauthorized.socket/g' \
    -e 's/two-result/unauthorized/g' -e 's/two-daemon/unauthorized-daemon/g' "$root/two-result-part.sh" > "$root/unauthorized-part.sh"
sed -i "/^set -euo pipefail$/a\\
export GOONIX_BAD_URL='$retry_port'" "$root/unauthorized-part.sh"
sed -i "s#^export GOONIX_BAD_URL=.*#export GOONIX_BAD_URL='http://127.0.0.1:$retry_port'#" "$root/unauthorized-part.sh"
sed -i "s#unauthorized \"$root/fixture.scm\"#unauthorized \"$root/fixture.scm\" >\"$root/unauthorized-client.log\" 2>\&1#" "$root/unauthorized-part.sh"
unshare --user --map-root-user --mount bash -c \
  "mount --bind '$client/unauthorized-store' '$store' && exec unshare --user --map-user=$(id -u) --map-group=$(id -g) bash '$root/unauthorized-part.sh'"
grep -F 'graph cache for' "$root/unauthorized-client.log" | grep -F 'refused'
kill "$bad_pid"; wait "$bad_pid" 2>/dev/null || true

# still work for another top-level derivation in the same request.
mkdir -p "$client/dead-store" "$client/dead-db" "$client/dead-state" "$client/dead-log"
cat > "$root/dead-part.sh" <<EOF
set -euo pipefail
export NIX_STORE_DIR=$store GUIX_DATABASE_DIRECTORY=$client/dead-db
export GUIX_CONFIGURATION_DIRECTORY=$client/etc GUIX_STATE_DIRECTORY=$client/dead-state
export GUIX_DAEMON_SOCKET=$client/dead.socket GUIX_LOG_DIRECTORY=$client/dead-log
export GOONIX_SERVER_URL=$url GOONIX_SERVER_STORE=$store
export GOONIX_SHELL_SOURCE=$root/shell GOONIX_BUILD_MARKER=$root/server-build-marker
export GOONIX_REAL_GUIX=$PWD/scripts/guix
cat > "$root/dead-guix" <<'INNER'
#!/bin/sh
if test "\$1 \$2" = "substitute --goonix-graph"; then exit 42; fi
exec "\$GOONIX_REAL_GUIX" "\$@"
INNER
chmod 755 "$root/dead-guix"
export GUIX=$root/dead-guix
while IFS= read -r line; do export "\$line"; done < <(
  ./pre-inst-env perl -MEnv -e 'for \$v (qw(GUILE_LOAD_PATH GUILE_LOAD_COMPILED_PATH GOONIX_DEEP_SCAN_HELPER)) { print "\$v=\$ENV{\$v}\\n" }'
)
./guix-daemon --disable-chroot --listen="\$GUIX_DAEMON_SOCKET" \
  --substitute-urls="\$GOONIX_SERVER_URL" --max-jobs=1 \
  >"$root/dead-daemon.log" 2>&1 &
pid=\$!
trap 'kill "\$pid" 2>/dev/null || true' EXIT
for i in \$(seq 1 100); do test -S "\$GUIX_DAEMON_SOCKET" && break; sleep .1; done
./pre-inst-env guile --no-auto-compile tests/ca-two-store-fixture.scm \
  dead "$root/fixture.scm"
EOF
before=$(grep -c '^GET /nar/' "$root/publish.log" || true)
unshare --user --map-root-user --mount bash -c \
  "mount --bind '$client/dead-store' '$store' && exec unshare --user --map-user=$(id -u) --map-group=$(id -g) bash '$root/dead-part.sh'"
after=$(grep -c '^GET /nar/' "$root/publish.log" || true)
test "$after" -gt "$before"
# The client log is the observable build output; the request count and nar
# response prove that graph failure did not disable ordinary substitution.

for mode in daemon client; do
  before=$(grep -c '^GET /goonix/records/' "$root/publish.log" || true)
  no_store=$client/no-sub-$mode-store
  mkdir -p "$no_store"
  cat > "$root/no-substitutes-$mode-part.sh" <<EOF
set -euo pipefail
export NIX_STORE_DIR=$store GUIX_DATABASE_DIRECTORY=$client/no-sub-$mode-db
export GUIX_CONFIGURATION_DIRECTORY=$client/etc GUIX_STATE_DIRECTORY=$client/no-sub-$mode-state
export GUIX_DAEMON_SOCKET=$client/no-sub-$mode.socket GUIX_LOG_DIRECTORY=$client/no-sub-$mode-log
export GOONIX_SHELL_SOURCE=$root/shell GOONIX_BUILD_MARKER=$root/server-build-marker
export GOONIX_NO_SUBSTITUTES_MODE=$mode
mkdir -p "\$GUIX_DATABASE_DIRECTORY" "\$GUIX_STATE_DIRECTORY" "\$GUIX_LOG_DIRECTORY"
./pre-inst-env ./guix-daemon --disable-chroot \
  $(test "$mode" = daemon && printf '%s' '--no-substitutes') \
  --substitute-urls="$url" --listen="\$GUIX_DAEMON_SOCKET" >"$root/no-substitutes-$mode-daemon.log" 2>&1 &
pid=\$!
trap 'kill "\$pid" 2>/dev/null || true' EXIT
for i in \$(seq 1 100); do test -S "\$GUIX_DAEMON_SOCKET" && break; sleep .1; done
./pre-inst-env guile --no-auto-compile tests/ca-two-store-fixture.scm \
  no-substitutes "$root/fixture.scm"
EOF
  printf 'part: no-substitutes-%s\n' "$mode"
  unshare --user --map-root-user --mount bash -c \
    "mount --bind '$no_store' '$store' && exec unshare --user --map-user=$(id -u) --map-group=$(id -g) bash '$root/no-substitutes-$mode-part.sh'"
  after=$(grep -c '^GET /goonix/records/' "$root/publish.log" || true)
  test "$before" -eq "$after"
done
completed=true
printf 'two-store graph sharing: PASS\n'

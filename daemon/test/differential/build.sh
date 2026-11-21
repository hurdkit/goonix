#!/usr/bin/env bash
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
. "$root/daemon/test/lib.sh"
fixture=${1:-/tmp/goonix-hs4-build}
"$root/daemon/test/differential/prepare-write-fixture.sh" "$fixture"
export NIX_STORE_DIR="$fixture/store" GUIX_DATABASE_DIRECTORY="$fixture/db" GUIX_STATE_DIRECTORY="$fixture/var" GUIX_DAEMON_SOCKET="$fixture/var/socket"
hs=$root/guix-daemon
daemon=${GOONIX_TEST_DAEMON:-$hs}
read -r -a daemon_options <<< "${GOONIX_TEST_DAEMON_OPTIONS:---disable-chroot --no-substitutes}"
goonix_start_capped "$root/pre-inst-env" "$daemon" "${daemon_options[@]}" --listen="$GUIX_DAEMON_SOCKET" >"$fixture/daemon.log" 2>&1
pid=$GOONIX_TEST_PID
scope=$GOONIX_TEST_SCOPE
trap 'goonix_stop_capped "$pid" "$scope"' EXIT
for i in $(seq 1 200); do test -S "$GUIX_DAEMON_SOCKET" && break; kill -0 "$pid"; sleep .01; done
goonix_run_capped "$root/pre-inst-env" guile --no-auto-compile -c '
(use-modules (guix store) (guix derivations) (guix tests) (guix packages) (ice-9 textual-ports))
(let* ((s (open-connection))
       (script (add-text-to-store s "build.sh" "printf hello > $out\n" (list)))
       (bash (add-to-store s "bash" #t "sha256" (search-bootstrap-binary "bash" (%current-system))))
       (drv (derivation s "hello" bash (list "-e" script) #:inputs (list (list bash) (list script))))
       (out (derivation->output-path drv)))
  (format #t "drv=~a out=~a\n" (derivation-file-name drv) out)
  (format #t "build=~s\n" (build-derivations s (list drv)))
  (format #t "valid=~s contents=~s derivers=~s\n" (valid-path? s out) (call-with-input-file out get-string-all) (valid-derivers s out)))
' >"$fixture/client.log" 2>&1
cat "$fixture/client.log"

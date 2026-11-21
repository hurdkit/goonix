#!/usr/bin/env bash
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
exec "$root/pre-inst-env" guile --no-auto-compile \
  "$root/daemon/test/offload/helper.scm" "$@"

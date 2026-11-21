#!/usr/bin/env bash
# pre-inst-env exits after its command; restore GUIX inside that command.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
recorder="${GOONIX_TRANSCRIPT_RECORDER:-$root/daemon/test/transcripts/record-helper}"
export GOONIX_RECORD_HELPER="$recorder"
exec "$root/pre-inst-env" bash -c 'export GUIX="$GOONIX_RECORD_HELPER"; exec "$@"' bash "$@"

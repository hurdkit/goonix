#!/usr/bin/env bash
# HS-9 guest runtime probe gate.
# Builds and runs HurdRuntimeProbe with the threaded runtime. On the Linux host
# this validates the probe's own logic; the GATE is the same run inside the
# x86_64-pc-gnu guest once a Hurd-targeting GHC exists (STATUS.md HS-9 E4).
# Usage: gate.sh [GHC]   (GHC defaults to ghc in PATH)
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ghc=${1:-ghc}
work=$(mktemp -d /tmp/hs9-probe-gate.XXXXXX)
trap 'rm -rf "$work"' EXIT
"$ghc" -threaded -rtsopts -with-rtsopts=-N -O2 \
    -outputdir "$work" -o "$work/HurdRuntimeProbe" \
    "$here/HurdRuntimeProbe.hs" "$here/socketpair.c"
"$work/HurdRuntimeProbe" +RTS -N2
#!/usr/bin/env bash
# goonix: the COMMON ca-scan real-store fixture is fixed and count-stable.
# Daemon-free regression (the scanner reads bytes, no store connection).  Builds
# the fixture twice, asserts its shape (5 items, 60 files), determinism, and the
# sweep/single-pass agreement on every file — the property tests/ca-scan.scm's
# real-store group asserts, here on a fixed tree so the count is the same on z2
# and on the laptop.  Does NOT touch tests/ca-scan.scm.
#
# Usage: scan-real-store.sh   (run inside the dev shell / pre-inst-env so that
#         (guix ca scan) resolves; the wrapper sets the load path itself.)
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
. "$here/lib.sh"
export GUILE_AUTO_COMPILE=0
# (guix ca scan) and its dependencies live in the build tree; guile-gcrypt etc.
# come from the caller's dev-shell GUILE_LOAD_PATH.
goonix_run_capped guile --no-auto-compile -L "$root" -s "$here/scan-real-store.scm"
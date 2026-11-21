#!/bin/sh
# GNU Guix --- Functional package management for GNU
# This file is part of GNU Guix.
# GNU Guix is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version.

set -eu

probe_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sandbox_dir=$(CDPATH= cd -- "$probe_dir/../../sandbox" && pwd)
build_dir=${P2_BUILD_DIR:-"$probe_dir/.build"}
rm -rf "$build_dir"
mkdir -p "$build_dir/ghc" "$build_dir/run"

: "${CC:=cc}"
: "${CXX:=c++}"
: "${GHC:=ghc}"
: "${MAKE:=make}"

# Build into the probe's scratch area; do not require the parent build to
# modify daemon/sandbox or write outside the assigned directories.
"$MAKE" -B -C "$sandbox_dir" -f Makefile \
    CXX="$CXX" TARGET="$build_dir/guix-sandbox"
"$CC" ${CPPFLAGS:-} ${CFLAGS:--O2} -Wall -Wextra -Wpedantic -std=c11 \
    "$probe_dir/child-inspect.c" ${LDFLAGS:-} ${LDLIBS:-} \
    -o "$build_dir/child-inspect"
"$GHC" -Wall -O1 -threaded -rtsopts \
    -package base -package bytestring -package unix \
    -outputdir "$build_dir/ghc" -odir "$build_dir" -hidir "$build_dir" \
    "$probe_dir/ThreadedUnshareProbe.hs" "$probe_dir/spawn.c" \
    -o "$build_dir/threaded-unshare-probe"

helper=$build_dir/guix-sandbox
child=$build_dir/child-inspect
probe=$build_dir/threaded-unshare-probe
work=$build_dir/run
case $helper:$child:$probe:$work in
    /*:/*:/*:/*) ;;
    *)
        helper=$(CDPATH= cd -- "$(dirname -- "$helper")" && pwd)/$(basename -- "$helper")
        child=$(CDPATH= cd -- "$(dirname -- "$child")" && pwd)/$(basename -- "$child")
        probe=$(CDPATH= cd -- "$(dirname -- "$probe")" && pwd)/$(basename -- "$probe")
        work=$(CDPATH= cd -- "$work" && pwd)
        ;;
esac

# ThreadedUnshareProbe fails unless all of these hold:
#   - the no-namespace plan passes identity/session/stdin/env/exec checks;
#   - the process has more than one live runtime thread;
#   - its direct unshare(CLONE_NEWUSER) fails with EINVAL (22);
#   - the external plan writer creates the uid/gid maps and execs the child.
"$probe" "$helper" "$work" "$child"

GNU Guix --- Functional package management for GNU
This file is part of GNU Guix.
GNU Guix is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option)
any later version.

P2 threaded-user-namespace probe
================================

gate.sh builds ../../sandbox/guix-sandbox.cc, child-inspect.c, and
ThreadedUnshareProbe.hs, then runs two plans.  CC, CXX, GHC, and MAKE select
the toolchain.  P2_BUILD_DIR selects the scratch directory; it defaults to
.build next to this file and is ignored by git.  For example:

  CC=gcc CXX=g++ GHC=ghc MAKE=make \
    sh daemon/test/sandbox-probe/gate.sh

The parent owns integration into the Cabal test suite.  No result file is
kept here; the program's exit status is the gate.

What the probe establishes
==========================

* ThreadedUnshareProbe.hs is linked with -threaded.  It holds an additional
  bound thread open and counts entries in /proc/self/task.  It refuses to
  proceed unless the count is greater than one.
* spawn.c calls unshare(CLONE_NEWUSER) directly in that threaded process.
  The gate requires failure with errno 22 (EINVAL).  EPERM, ENOSYS, and an
  unexpected success are failures, not evidence for the H4 premise.
* The same process then calls the actual posix_spawn function through
  spawn.c.  It never uses forkProcess and passes no Haskell callback or
  post-fork action to a child.
* The external helper reads a byte-oriented plan, creates its user namespace,
  receives its one-entry uid/gid maps from the C++ map-writer child, and
  execs child-inspect.  The inspector must report the expected zero IDs and
  mappings and print namespace-ready=1.  Exit status alone is insufficient.

The first plan checks basic exec behavior without a user namespace: a
non-UTF-8 argument byte, an argument containing spaces, an explicitly reduced
environment, working directory, inherited uid/gid, session leadership,
no_new_privs, descriptor closure, and file-backed stdin.

Platform assumptions and boundaries
===================================

This is a Linux probe.  It needs unprivileged user namespaces enabled and
permission to make the one-entry current-user map.  Missing kernel support,
a restrictive system policy, or a non-Linux host is a failed/inconclusive
probe for that host and must be reported as such.  The shell script does not
turn those cases into skips.

The map check is not a test of mount, chroot, network, PID, IPC, UTS, build
user, multi-ID, supplementary-group, or seccomp behavior.  Those belong to
HS-6.  See ../../sandbox/README.md for the plan format and the differences
from upstream spawn.cc/seccomp.cc.

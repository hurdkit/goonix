GNU Guix --- Functional package management for GNU
This file is part of GNU Guix.
GNU Guix is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option)
any later version.

Upstream reuse boundary
=======================

H4 calls for an initial helper from the committed spawn.cc and seccomp.cc.
Literal, unchanged reuse was not practical for a standalone plan interpreter:

* spawn.cc includes spawn.hh, util.hh, and affinity.hh.  It relies on the
  daemon's Error/SysError classes, file descriptor owners, Pipe, logging
  hook, global affinity state, and configure-generated feature macros.
* Its clone path depends on the parent in libstore/build.cc writing the
  namespace ID maps and synchronizing with the child.  That parent would be
  the threaded Haskell daemon in a direct port, which is the arrangement P2
  is intended to avoid.
* seccomp.cc is a BPF-vector builder, not a complete sandbox policy.  It also
  uses libutil types and does not supply the plan parsing or process setup
  needed here.  Full filter construction and installation belong to HS-6.

The standalone helper therefore retains the basic spawn phase ordering,
checks, error phase labels, and the two-process user namespace map handoff,
with small local equivalents for the utility operations.  The exact plan
format and the omitted features are specified in ../../sandbox/README.md.
The derived helper retains GNU Guix's GPL-3.0-or-later licensing and the
upstream spawn.cc copyright notice.  This is a narrowed derivative, not an
unchanged copy and not an assertion of HS-6 sandbox compatibility.

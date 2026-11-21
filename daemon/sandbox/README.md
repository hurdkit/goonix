GNU Guix --- Functional package management for GNU
Copyright (C) 2025 Caleb Ristvedt <reepca@russelstein.xyz>

This directory contains an initial, standalone guix-sandbox for HS-0/P2.
It executes a data plan in an external process.  The daemon must start it
with posix_spawn (or an equivalent exec-only child primitive), never by
running Haskell code after fork.

This is not the HS-6 sandbox.  It supports a single-entry unprivileged user
namespace and the basic spawn phases.  It has no mount namespace, chroot,
pivot_root, network namespace, build-user management, supplementary ID-map
entries, or sandbox seccomp policy.

Build
=====

  make -C daemon/sandbox CXX=g++

The only build dependency is a C++17 compiler and the Linux/POSIX headers.
No generated config.h or other part of libutil is needed.

Invocation
==========

  guix-sandbox PLAN

PLAN is an open file containing exactly one version-1 plan.  On success,
guix-sandbox execs the requested program directly; its pid and exit status
therefore remain visible to the daemon.  Plan and setup errors go to stderr
and exit with status 1.

Plan format
===========

Integers are unsigned 32-bit little-endian values.  A byte string is a u32
length followed by that many bytes.  Byte strings may contain any non-NUL
byte, including newlines and non-UTF-8 data.  Lengths are limited to 1 MiB
per string and a plan is limited to 1 MiB.  Counts are checked against the
remaining input.  Unknown versions and trailing bytes are rejected.

The header is the eight ASCII bytes "GSP0001\0".  It is followed by:

  u32 flags
  byte_string program
  u32 argc, then argc byte_strings argv
  u32 envc, then envc pairs of byte_strings (name, value)
  byte_string workingDirectory
  byte_string stdinFile
  u32 uid, gid
  u32 stdinFd, logFd
  u32 supplementaryGroupCount, then that many u32 group IDs
  u32 earlyCloseFdCount, then that many u32 descriptors
  u32 uidMapInside, uidMapOutside
  u32 gidMapInside, gidMapOutside

FLAGS is a bit set:

  1  SET_IDS          set supplementary groups, gid, then uid
  2  SET_SID          create a new session
  4  CLOSE_FDS        close descriptors other than 0, 1, and 2
  8  NEW_USER_NS      unshare(CLONE_NEWUSER) and install one uid/gid map
  16 INHERIT_ENV      apply env to the inherited environment
  32 CHDIR            chdir(workingDirectory)
  64 SET_STDIN_FILE   open stdinFile O_RDWR and dup it to stdin
  128 SET_STDIN_FD    dup stdinFd to stdin
  256 CLEAR_GROUPS    set an empty supplementary group list
  512 NO_NEW_PRIVS    prctl(PR_SET_NO_NEW_PRIVS)
  1024 SETUP_SUCCESS  write a newline to stderr after all other setup
  2048 REDIRECT_LOG   dup logFd to both stdout and stderr

No other flag is accepted.  SET_STDIN_FILE and SET_STDIN_FD are mutually
exclusive.  stdinFd/logFd are either an actual descriptor or 0xffffffff for
absent.  REDIRECT_LOG requires a present logFd.  fd-backed stdin and log
redirection require descriptors above stderr.  earlyCloseFdCount lists
descriptors closed before redirection.  If a descriptor is redirected it
must not also occur in that list.

uidMapOutside and gidMapOutside are the caller's IDs, not names.  The mapping
has length one.  The map writer denies setgroups before writing gid_map, as
unprivileged user namespace setup requires.  With NEW_USER_NS, uid/gid in
the plan are set to the corresponding Inside values before the basic ID
phase; CLEAR_GROUPS is useful when SET_IDS must not attempt setgroups after
that denial.  Outside a user namespace, SET_IDS uses uid/gid directly.

INHERIT_ENV=false constructs the environment solely from the env pairs.
The first argv string is argv[0]; program is not implicitly prepended.
CHDIR occurs after user namespace setup.  CLOSE_FDS closes all descriptors
above stderr.  The helper reads the complete plan before unshare and keeps
no plan descriptor or synchronization descriptor open across exec.

Phase order
===========

The order follows getBasicSpawnPhases and unshareAndInitUserns in
nix/libutil/spawn.cc:

  user namespace unshare and map handoff
  namespace uid/gid selection
  setsid
  open/redirect stdin
  chdir
  close descriptors
  set supplementary groups, gid, uid
  set no_new_privs
  restore default SIGPIPE disposition
  optional setup-success newline
  execvpe

A small C++ child writes uid_map, setgroups, and gid_map while the target
process waits in its new user namespace.  This retains the reason for
upstream's two-process handshake: the process which unshares may lose the
parent-namespace capabilities needed to write its own maps.  For the
single-entry unprivileged map this also keeps all post-fork work in the
external helper rather than in the threaded daemon.

Source relation and deliberate differences
==========================================

The child setup sequence, system-call checks, map handshake, and error phase
reporting are derived from committed nix/libutil/spawn.cc at branch base
6cc37ea5e3f.  The utility routines correspond to util.cc's readFull,
writeFull, waitForMessage, stringsToCharPtrs, and closeMostFDs.  GNU Guix's
GPL-3.0-or-later terms and upstream copyright notice are retained.

Literal reuse of spawn.cc was impractical for this standalone first step.
It includes spawn.hh, util.hh, and affinity.hh; uses the daemon's Error,
SysError, AutoCloseFD, Pipe, logging hook, and global affinity state; and
expects configure-generated HAVE_* and CLONE_ENABLED definitions.  Its
cloneChild stack lifetime is tied to libstore/build.cc's parent-side map
setup.  Copying that file would therefore still leave a daemon-linked
helper rather than a plan interpreter.

This implementation keeps the basic phases and their order but omits the
daemon-only reset_writeToStderr and restoreAffinity phases.  chroot,
personality, ambient capabilities, OOM adjustment, seccomp filter loading,
and all clone/chroot phases are intentionally absent.  Their data-plan
representation belongs with the HS-6 sandbox implementation.

nix/libutil/seccomp.cc was also read.  It builds BPF instruction vectors,
not an execution plan or a complete filter, and likewise depends on
libutil's Error and Uint32RangeAction definitions.  No seccomp source is
copied here merely to make the helper look complete.  Installing a filter
and translating the full upstream policy are HS-6 work.

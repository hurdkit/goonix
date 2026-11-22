# Deliberate differences from the C++ daemon

Every intentional behaviour difference must name the affected item in the
behaviour inventory.  Incidental differences found by differential testing
are defects, not entries here.

The process model is one threaded process rather than one process per client
(H5; inventory 1.1). Each client still has its own SQLite connection. Database
statements and transactions on one client's connection are serialized against
that connection's concurrent engine jobs, so one client registering a path can
make another job of the same client wait for a query. Other clients' ordinary
queries do not take that per-connection lock. Client startup briefly shares a
process-wide lock for SQLite WAL setup, schema creation, and statement
preparation. The C++ daemon instead isolates each client in its own process.
  The client PID is not written over `argv[1]`
(inventory 1.1 and 9.25).  A vanished client is handled by cancelling its
Haskell thread rather than by the `SIGPOLL` flag (inventory 1.3).

Because it is one process, the daemon also creates the store and state
directories once at start-up (`initialiseState`) rather than per client as the
C++ `LocalStore` constructor does on each connection (inventory 1.1). The
observable on-disk layout after a connection differs in these incidental ways,
none of which changes the store's behaviour:

- The GC lock is `STATE/gc.lock` here, `DB/big-lock` in C++ (inventory 5.3).
  Both are process-wide exclusive locks for collection; the path is internal.
- `gcroots/auto` is created at start-up here; C++ creates it lazily when the
  first indirect root is added. Both daemons read it when finding roots.
- C++ writes a `DB/schema` version file and creates `STORE/.links` at store
  open; here the schema is applied from the compiled SQL on each open and
  `.links` is created on the first deduplication. Neither is read by a client.
- C++ creates the `gcroots/profiles -> profiles` symlink at store open. It is
  redundant: both root walkers scan `profiles` directly and follow a
  symlink-to-directory no further, so the symlink adds no root. It is not
  created here.

The Unix-socket start-up itself matches the C++ `open_unix_domain_socket`
exactly (create the socket directory, chdir and bind the relative `./socket`,
unlink a stale socket, bind 0666 under `umask(0111)`, chdir back, listen); see
`daemon/test/differential/socket-startup.sh`.

Recursive NAR uploads and hash rewriting are streamed instead of retaining a
whole store item in memory (inventory 9.20).

The optional `build-separate-download-slots` setting gives download jobs their
own `build-max-download-jobs` limit (inventory 5.2). It is off by default:
substitutions and builders share `build-max-jobs`, as in the C++ daemon. The
setting is not enabled in parity comparisons and must not be enabled before
those comparisons pass and the user asks for it.

The build scheduler is shared across the clients of one daemon (HS-12;
DECISIONS.md point 2; inventory 5.1). There is one job limit and one goal per
derivation across all clients, as in the C++ daemon's single goal loop:

- One job limit: a process-wide running-job count bounds all clients together.
  A client's `build-max-jobs` raises the shared limit (the C++ daemon reads the
  connection's setting), so the shared limit is never tighter than a client's
  request. Each request still bounds its own jobs by its `build-max-jobs`.
- One goal per derivation: the first client to reach a derivation's build phase
  starts the build in a daemon-owned worker thread; a later client asking for
  the same derivation attaches to that goal and shares its result instead of
  starting a second builder. The goal owns its temporary roots and its store
  handle and tolerates a gone client's trace, so it outlives the client that
  started it while any other client is still interested. When the last
  interested client disconnects, the worker is killed — a single client's
  disconnect still kills its build, as before.

Goal sharing is bounded by two rules, so a client gets what it would get from
the C++ daemon, where each client has its own goals and clients meet only at the
output locks:

- Goals are shared only between Normal-mode requests. A Check or Repair request
  always runs its own build: attaching a check to a normal goal would check
  nothing, and attaching a normal request to a check goal would take "success"
  from a build that writes redirected paths and registers nothing.
- Only success is shared. The starter gets the goal's failure (it ran the build
  with its own settings); a waiter whose goal failed runs its own attempt with
  its own settings, as a waiter on the output lock would. The goal may have
  failed because of the starter's settings (max-silent-time, timeout,
  keep-failed, the substituters it allows) or a transient fault, which need not
  apply to the waiter. The failure cache, when enabled, stays the only shared
  failure, as in C++.

The lock files stay, for helpers and for other daemons: this sharing is
in-process only. Two daemon processes on one store still serialize through the
output locks and the GC lock. The observable build results are unchanged from
the C++ daemon (tests/guix-build.sh, the engine differential tests, and the
two-client build test pass identically); the difference is that the job limit
and goal deduplication are shared across clients rather than per connection.

The collector no longer holds the global GC lock against the other threads of
this process for a whole collection (DECISIONS.md point 3, after parity;
inventory 5.3). A running collector learns of new roots from the other
connections through a shared STM announcement table, keyed by the store's
GC-lock path and then by each connection's temporary-root file path, and re-reads
the other connections' announcements before each deletion. A root registered
while a collection runs is therefore kept. A connection's announcements are
withdrawn when its temporary-root file is released, and the requesting
connection's own announcements are omitted, exactly as the C++ daemon omits the
requester's own temporary-root file.

A new client skips the shared GC lock at temporary-root-file creation only while
THIS process's own collector holds the GC lock (a process-wide STM flag records
that); that collector reads the announcements, so the new root is still kept.
Against another process's collector — a C++ daemon or a second Haskell daemon on
the same store — the shared lock is still taken and the new client waits, because
that collector cannot see this process's announcements and the shared lock at
creation is what guarantees no temporary-root file appears after it has
enumerated the directory. So a new client waits only for another process's
collection, never for its own process's. The GC lock file is still held
exclusively for the collection, so two daemon processes on one store still
exclude each other through the lock files. The observable live/dead sets and
collection results are unchanged from the C++ daemon (tests/guix-gc.sh and the
collector tests of tests/store.scm pass identically); the difference is only that
in-process builds and clients are not blocked for the duration of their own
process's collection.

The build-user pool reads `/etc/passwd` and `/etc/group` directly rather than
calling `getgrnam`, `getpwnam`, and `getgrouplist` (inventory 4.1). This keeps
identity parsing independent of NSS modules in the static/test daemon; the
group file paths can be overridden for the guest tests. The selected group's
GID is used as the builder GID, and its members' other group entries become
supplementary groups. UID 0 and the daemon's own UID are rejected. Each lease
holds the nonblocking `STATE/userpool/UID` lock through the shared file-lock
table, so another daemon process cannot use the same build user. Unrelated
malformed passwd/group lines are ignored; selected identities are validated.

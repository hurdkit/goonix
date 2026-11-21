HS-0 C++ daemon transcripts
===========================

`inventory.wire.log` was captured by `goonix-wire-proxy` between the
unmodified Scheme client and the C++ daemon at baseline 6cc37ea5e3f.  The
client, daemon and store were all in the HS-0 worktree.  No system store or
system daemon was used.  `inventory-client.log` records the corresponding
client-visible results.  The source probe is `../wire-proxy/inventory.scm`.

The capture confirms these inventory statements:

* 9.1: the exchange contains client magic, server magic/version, client
  version/affinity/reserve-space, then exactly one `STDERR_LAST` before the
  first operation.  There are no `STDERR_NEXT` frames in this handshake.  The
  client completes it successfully.  The Scheme expression named as a loop
  calls `process-stderr` at most twice, so the replacement must send at most
  one `STDERR_NEXT` there.  Lock-contention logging was not induced; this
  capture does not independently prove the warning text for that case.
* 9.6: `wopBuildThings` for a missing non-derivation returns `#t` while no
  substituter is available.  The following `wopEnsurePath` for the same path
  returns `STDERR_ERROR`, "does not exist and cannot be created", status 1.
* 9.7: `wopBuildThings` in check mode for that non-derivation also returns
  `#t`.  The request has mode 2.  This does not distinguish whether the C++
  goal treats that mode as a boolean internally; the client-visible behavior
  is established.
* 9.9: with pretty logging, verbosity 1 and build traces enabled, a real
  build's `STDERR_NEXT` string begins `|   @ build-started`, not
  `@ build-started`.  The corresponding `@ build-succeeded` line has no
  nesting prefix.  The builds succeeded.  The host's newgidmap policy also
  emitted an ignored diagnostic; it did not change this result.

The raw lines in the transcript are hexadecimal and lossless.  Parsed field
labels are descriptive.  The proxy never rewrites forwarded traffic.

For the full Guix suite, set `GOONIX_WIRE_GZIP=1` together with
`GOONIX_WIRE_PROXY`.  The proxy then writes a gzip-compressed transcript
with the same raw lines and offsets; it does not drop frames or payload.
The default remains plain text for targeted inspection.  The test harness
uses this option to bound scratch space during long store-population tests.

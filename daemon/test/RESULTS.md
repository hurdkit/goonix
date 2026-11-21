# HS-0 verification

All results below were observed in the `goonix-daemon-hs` worktree.  The
C++ baseline is commit `6cc37ea5e3fa1472499a34ad424d8be221b34c97`.

* The recording proxy passed its Cabal test and the direct `ghc --make`
  runner.  Tests include real Unix sockets, arbitrary bytes, fragmented
  frames, half-close, abrupt disconnect, concurrent clients and SIGTERM.
* The selected C++ baseline completed with 547 total, 540 pass, 7 skip,
  0 fail and 0 error.  `store.scm` contains 106 PASS and one SKIP,
  `store: kvm GID is mapped`; it was not skipped as a file.  The complete
  per-test list is in the worktree's `hs0-baseline-trs/` directory.
* The clean baseline followed two environment fixes: a disconnected FUSE
  mount was removed with the real privileged wrapper, and the inherited
  Guile 3 compiled-module path is cleared for test programs.  Fixed-output
  networking in `derivations.scm` and the affected `packages.scm` tests
  now pass.  `gexp.scm` has only its two original skips.
* The same 13 tests through the proxy also completed with 547 total,
  540 pass, 7 skip, 0 fail and 0 error.  `compare-trs.sh` reported every
  result file unchanged, comparing all test names and PASS/FAIL/SKIP
  entries.  The full run used `GOONIX_WIRE_GZIP=1`, which preserves every
  raw frame byte while compressing the transcript.  It did not use a
  privileged daemon.
* The real client transcript in `transcripts/inventory.wire.log` confirms
  inventory 9.6, 9.7 and 9.9 at the wire/client boundary.  The ordinary
  handshake and the two-call client bound for 9.1 are recorded there; no
  lock-contention warning was induced.
* P1 fails as a Hurd probe: the pinned `pkgsCross.gnu64` output has Linux
  build, host and target triples.  It runs on the host, not in a Hurd guest.
* P2 passes on this Linux host from a clean build.  Direct unshare in a
  threaded process fails with `EINVAL`; the external helper succeeds.  This
  does not test HS-6's full sandbox.
* Both configure modes and the no-GHC branch build the intended daemon.
  The direct-build/Cabal flag comparison passes.  No default package,
  deployment, system store, Hurd image, or C++ removal is changed here.

The generated full-store vector directory is ignored and retained locally
for HS-1.  Its completed manifest and SHA256SUMS are the evidence of the
input set; large raw NARs and transient test logs are not committed.

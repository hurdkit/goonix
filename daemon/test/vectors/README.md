Format vectors
==============

Generate vectors from a populated store without starting a daemon or
writing to that store:

  nix develop . -c sh daemon/test/vectors/generate.sh STORE OUTPUT GHC

OUTPUT must not exist.  It receives a copy of every `.drv`, streaming C++
SHA-256 hashes and lengths for every non-derivation store item, C++ derivation
modulo hashes for every copied `.drv`, and a bounded sample of complete
C++-generated NARs.  The sample is capped at
268435456 bytes; its candidates cover regular, executable, symlink,
directory, empty-file, empty-directory and large-file nodes.  A manifest
and SHA256 checksum manifest are included.  Daemon lock and chroot state
are excluded; they are not store items.  STORE is read-only input and
must not be collected or modified.

The NAR dumper is linked from the baseline's own `archive.cc`,
`serialise.cc`, `util.cc` and `affinity.cc`.  The vectors are evidence for
HS-1's parser, printer and hash comparisons, not a substitute for those
checks.  Raw vectors and generated binaries stay outside the commit; the
selected inventory transcript is retained under `../transcripts`.

The manifest records the input store and the number and byte sizes of the
vectors.  A failed archive is fatal: no incomplete run is reported as a
complete whole-store input set.

Run the HS-1 gates from the repository root after generation:

  nix develop .#daemon -c sh -c 'cd daemon && cabal test format-properties'
  nix develop .#daemon -c sh -c 'cd daemon && cabal test format-vectors \
    --test-option="$PWD/../OUTPUT"'

The shorter `sample` argument checks the raw NAR sample and every derivation
without repeating the whole-store NAR hash pass.  All derivations must parse
and print byte-identically.  Input-addressed derivations also compare their
modulo hash and output paths with the C++ oracle.  The two `ca-probe.drv`
files whose `goonixAddressing` is `content` belong to the deferred HS-11
experiment; they retain parse/print coverage but their output paths are not
input-addressed C++ daemon outputs and are reported as deferred.

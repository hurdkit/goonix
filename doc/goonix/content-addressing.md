# goonix content-addressed derivations, format 1

This document is normative.  Its test vectors are shared by the C++ daemon
and the Scheme implementation.  All multi-byte integers are unsigned,
little-endian 64-bit values.  Strings and byte strings are encoded as a
64-bit length followed by exactly that many bytes.  Directory entry names
are raw filesystem bytes and are ordered by unsigned byte value.

## Addressing metadata

Addressing is carried by the reserved environment entry `goonixAddressing`.
Its values are `content` and `resolved`; its absence means the historical
input-addressed format, which is unchanged.  `goonixResolved` has value `1`
in a resolved derivation.  These entries do not enter the builder's
environment.  `__files` names embedded builder-file entries, separated by
spaces.  Each `__file:<name>` entry contains its text.  Names are relative,
do not start with a dot or contain empty, `.` or `..` components.

## Tokens and placeholders

For a SHA-256 digest D, `reserved(D, kind)` produces 32 characters.  The
first character is `e` for a placeholder and one of `o`, `t`, `u` for a
self token, selected by D[0] modulo 3.  For character index i from 1 to
31, let bit = 2 + 2 * (i - 1); the character is `e`, `o`, `u`, `t` for the
two-bit value `(D[floor(bit / 8)] >> (6 - bit mod 8)) & 3`, respectively.

* self token: `reserved(SHA256(UTF8("goonix:self-token:v1:" + output)),
  token)`;
* placeholder: `reserved(SHA256(UTF8("goonix:placeholder:v1:" +
  decimal-length(unresolved-derivation-bytes) + ":" + output + ":") +
  unresolved-derivation-bytes), placeholder)`.

Both form `/gnu/store/TOKEN-NAME`.  A token depends only on the output
name.  A placeholder depends on the unresolved derivation's canonical bytes
and output name.  Neither can be a valid historical store hash.  A
placeholder must be decoded against a known derivation, never by guessing.
All daemon operations other than CA resolution reject reserved paths.

## Tree hash

`tree(path)` is SHA-256 of exactly one of the following encodings.  A hard
link is an ordinary file at every name.  Times, ownership and permission
bits other than the owner-executable bit do not participate.  Other file
types are errors.

* regular: `UTF8("goonix-tree-v1\0")`, byte 1, byte(executable ? 1 : 0),
  length-and-bytes(file content);
* symbolic link: the same prefix, byte 2, length-and-bytes(link target);
* directory: the same prefix, byte 3, 64-bit entry count, followed by each
  entry as length-and-bytes(name), length-and-bytes(hexadecimal child hash).

The root name is not included.  A directory is read and hashed one entry at
a time; no complete subtree or archive is buffered.  File content is read
in bounded chunks.  Tree walking never follows symbolic links.

## Content store path

Let `references` be the sorted, unique final store paths referred to by the
output, excluding its own final path and sibling output paths.  Compute

    name-hash = SHA256(UTF8("goonix-content-v1\0") +
                       64-bit-little-endian(length(tree-hash)) +
                       tree-hash-bytes +
                       64-bit-little-endian(count(references)) +
                       each reference as length-and-bytes(UTF8(path)))

Then apply Guix's existing `makeStorePath("goonix-content:" + output,
name-hash, name)`, which compresses SHA-256 of
`type + ":sha256:" + hex(name-hash) + ":" + store-directory + ":" + name`
to 20 bytes and prints it with Guix's little-endian base32 representation.

A resolved-addressed output instead uses
`makeStorePath("goonix-resolved:" + output,
SHA256(canonical-resolved-derivation-bytes), name)`.  Its output path is
known only after its inputs are resolved and it is built at that path.

## Resolution and records

Resolve all derivation inputs first.  Replace each input derivation/output
reference by the chosen realised output path, in arguments, builder,
ordinary environment entries, embedded builder files and `__files`.  Move
each such realised output to `inputSrcs`; a resolved derivation has no
`inputDrvs`.  Keep fixed-output paths unchanged.  A content output has its
self-token path in the resolved derivation; a resolved output has its
resolved-derived path.  Store the canonical resolved derivation with a
`.drv` suffix and use its canonical bytes as its identity.

A record format-1 S-expression contains `(format 1)`, `(resolved HASH)`,
`(derivation PATH)`, `(output NAME)`, `(path STORE-PATH)`, `(origin
DESCRIPTION)`, `(relocation-checked BOOLEAN)`, `(signature STRING)`.  The
record's content hash and signature are computed over the fields through
`relocation-checked`, in canonical written order.  Their exact signed payload
is `UTF8("goonix-record-v1\0")`, 64-bit integer 1, then the resolved hash,
derivation path, output name, output path and origin in that order, each as a
64-bit length followed by exactly that many bytes, then 64-bit integer 0 or 1
for `relocation-checked`.  The signature signs SHA-256 of this payload, with no
archive-stream padding.  Imported records are registered only after the
authenticator has both authorized the signer and returned this payload hash.
Facts are immutable and
multiple different paths for one resolved derivation/output are retained.
Choices are separate mutable `(original derivation, output) -> realised
store path` records.  Neither table has a foreign key to a store item;
both survive collection of `.drv` files and outputs.

The daemon signs local records with its store signing key.  Remote records
must be signed by an authorized key; an unsigned or unauthorized mapping
is not registered.  Archives of content outputs need no trusted narinfo:
their tree hashes, round trips and store paths verify intrinsically.
Resolved-addressed and input-addressed archives retain signed narinfos.

A prebuilt archive at an already resolved path is not a token-finalisation
proof.  In particular, the resolved glibc fixture consumes a placeholder that
resolves to its final path, but a downloaded archive of that same item can
carry a compiler-emitted or otherwise hidden reference to its own path without
passing through the content-output scanner.  Such archives require their
signed identity and, where that property matters, a separate local scan or
rebuild; their resolved path alone does not establish self-reference freedom.

## Finalisation

Canonicalise metadata, scan every file, symbolic-link target and directory
entry name, hash the canonical tree, rewrite whole token occurrences to the
final store hash (same length), rename entries depth-first, rename the
root, then map the final hash back to its token in memory and recompute the
tree hash.  Any mismatch, split-token fragment of at least eight characters
outside a whole occurrence, UTF-16/UTF-32 token, or reserved placeholder is
an output rejection naming the file and byte offset.  Ordinary finalisation
permits a self token hidden in a gzip member.  The client can request the
CA-1 policy with `set-build-options` keyword `deep-scan?`; it sends the
per-connection `goonix-deep-scan` setting, accepted from any client because
it only makes that connection's builds stricter.  It applies to builds
performed on that connection; an item that is already valid is not scanned
again.  Before finalization, the daemon runs the optional libexec `goonix-ca-scan` helper with every output token of the
derivation.  The helper, not the daemon, streams gzip, xz, bzip2 and ZIP
members and detects known output tokens and reserved placeholder paths.
It retains 32 bytes across decoded chunks, so the reserved pattern's `-`
can arrive in the next read.  On a root daemon the child clears supplementary
groups and assumes the still-held build user's UID and GID.  Under a
non-root daemon it runs as the daemon's own user: this is no reduction of
privilege.  Its standard input is `/dev/null`, its environment is empty, and
inherited descriptors are closed.  It has a one-hour whole-tree backstop and
no decoded-member size ceiling.  It runs outside the build's chroot and
namespaces: the build user's identity is what protects the host from a
decoder fault; under a non-root daemon there is no such protection.  Exit 0
is clean, including files that cannot be decoded after a recognized archive
signature: each such file is skipped with `skipped<TAB>FILE<TAB>REASON` on
standard error after the bytes decoded so far have been scanned.  Exit 1
reports `self-token` or `placeholder`, file and decoded offset.  Exit 2 is an
error that prevents scanning, such as an unreadable input, unsupported file
type, bad usage or allocation failure.  Missing helpers, crashes, timeouts,
malformed results and exit 2 refuse the build.  The daemon logs skipped-file
diagnostics at info level on a clean exit.  The daemon and libstore do not
link libarchive; deep scanning is opt-in and there is no daemon-wide switch.
Existing store items are never overwritten; a valid existing item must
round-trip to the same hash.

## Vectors

`tests/ca-vectors.json` is the shared input and expected-output set for the
independent C++ and Scheme implementations. Each side constructs the same
filesystem fixtures and parses the same canonical derivation and record
bytes; neither calls the other. The C++ side runs as
`nix/ca-test --shared-vectors` from `make check`; the Scheme side is
`tests/ca.scm`. The vectors cover empty files and directories, executable
bits, symbolic links, arbitrary-byte file contents, directory entry
ordering, self tokens, placeholders, content paths with sorted references,
resolved derivation serialization and paths, unresolved two-output
derivation serialization with an input derivation and its placeholder, and
canonical record payload bytes and hashes.

## Store self-reference scan

`guix ca scan` reads existing store items without changing them. It reports
whole plain self references, 8-character fragments outside whole occurrences,
UTF-16LE self references, self references in gzip or xz members, file names,
and symbolic-link targets. It reads regular files in bounded chunks and
retains enough overlap for a token crossing a read boundary. The counters
match the reference measurement: `files` excludes empty regular files,
`utf16` counts files containing at least one UTF-16LE hash, and `names`
counts every non-root entry name, including regular files and symlinks.
Whole plain occurrences are counted even when they overlap; the reference
skips 32 bytes after each match, which matters only for self-overlapping
hashes. `--format=jsonl` emits one object per item; the default `summary`
format prints the same counters in a readable line. `--directory=DIR` selects another store tree.
`--jobs=N` scans at most N items concurrently (three by default), while
retaining input order in the output.
Unsupported compressed members and decoding failures are counted separately;
they are not silently treated as clean. Gzip uses the strict inflate reader,
so truncated, damaged and non-gzip data are `undecodable`. Only one complete
member is scanned: a file with further members, padding or trailing bytes is
`unsupported`, including a damaged or header-only second member. The member's
trailer size and a separate full-file gzip read must agree with the strict
reader's decoded byte count. Empty compressed files are not decoded. Old lzma-alone, bzip2 and ZIP-family members are `unsupported`.
A gzip or xz member with more than 64 MiB of decompressed data is also
`unsupported`. The scan is a measurement tool, not the daemon's build
finaliser or its deep-scanning policy.

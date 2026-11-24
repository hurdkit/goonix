# The download cache

The built-in download builder can ask a cache on the local network for a
file before it asks the file's own URLs. The cache keeps what it has
served, so a file is fetched from its origin once; after that a build does
not depend on the origin answering.

## Turning it on

Set `GOONIX_DOWNLOAD_CACHE` to the base URL of the cache in the
environment of the daemon:

    GOONIX_DOWNLOAD_CACHE=http://cache.example:8480

The daemon runs `guix perform-download` for a `builtin:download`
derivation, and that program inherits the daemon's environment. Without
the variable nothing changes. A derivation is the same with and without a
cache: the variable is read when the download runs, not when the
derivation is made.

The test suite's daemon inherits the environment of `make check`, so the
same variable makes a fresh test store take its downloads from the cache.

## What is asked

For a file `NAME` whose derivation records the SHA-256 `HASH`, the first
request is

    GET BASE/file/NAME/sha256/HASH?url=ORIGIN&url=ORIGIN...

`HASH` is in the base-32 form that Guix prints. This is the form in which
`guix publish` serves a file by hash. Each `url` parameter is one of the
file's own URLs, with `mirror://` URLs expanded, and only HTTP, HTTPS and
FTP URLs are passed. They let a cache that lacks the file fetch it.

For a download that is made executable, the recorded hash is that of the
file as a normalised archive, not of its bytes. A cache that wants to keep
such files must accept both.

## What a cache answers

- `200` with the bytes of the file;
- anything else when it does not have the file and could not get it.

After any other answer, and when the cache cannot be reached, the download
goes on with the file's own URLs and the fallbacks, as without a cache.

## Trust

The daemon checks the hash of a fixed-output derivation's result whatever
its source, so a cache cannot make a build accept a different file. It
does not need TLS or a key.

## What it does not cover

Substitutes are not downloads of this kind: a cache for them is one more
entry in the daemon's `--substitute-urls`. Git checkouts
(`builtin:git-download`) are not asked from the cache. A builder that
fetches from the network itself is not affected.

The code is `(guix download-cache)`; the hook is one line in
`guix/scripts/perform-download.scm`; `tests/download-cache.scm` runs the
download program against a stand-in cache.

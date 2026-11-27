# The download cache

The built-in download builder can ask a cache on the local network for a
file before it asks the file's own URLs. The cache keeps what it has
served, so a file is fetched from its origin once; after that a build does
not depend on the origin answering. The same cache keeps copies of Git
repositories, which Git checkouts ask before the repository itself.

## Turning it on

Set `GOONIX_DOWNLOAD_CACHE` to the base URL of the cache in the
environment of the daemon:

    GOONIX_DOWNLOAD_CACHE=http://cache.example:8480

The daemon runs `guix perform-download` for a `builtin:download` or
`builtin:git-download` derivation, and that program inherits the daemon's
environment. For the checkouts that the `guix` command makes itself
(`guix pull`, `guix time-machine`, `guix style`, the importers, `guix
download --git`), set the variable in the environment of that command.
Without the variable nothing changes. A derivation is the same with and
without a cache: the variable is read when the download runs, not when the
derivation is made.

The test suite's daemon and test programs inherit the environment of `make
check`, so the same variable makes a fresh test store take its downloads
and checkouts from the cache.

## What is asked for a file

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

## What a cache answers for a file

- `200` with the bytes of the file;
- anything else when it does not have the file and could not get it.

After any other answer, and when the cache cannot be reached, the download
goes on with the file's own URLs and the fallbacks, as without a cache.

## What is asked for a Git repository

The copy of the repository at `SCHEME://REST` is the Git repository at

    BASE/git/SCHEME/REST

that is, the repository's URL with `://` written `/`: the copy of
`https://git.savannah.gnu.org/git/sed.git` is at
`BASE/git/https/git.savannah.gnu.org/git/sed.git`. Only HTTP and HTTPS
repositories are asked for, and not those whose URL has user information,
a query or a `.` or `..` segment. Git asks the copy as it asks any
repository over HTTP:

    GET  BASE/git/SCHEME/REST/info/refs?service=git-upload-pack
    POST BASE/git/SCHEME/REST/git-upload-pack

Before the first request of a process, a connection to the cache is
tried with a short limit; when it cannot be made, that process does not
ask the cache again, so a cache that cannot be reached delays a command by
that limit once.

- The built-in Git download checks out the derivation's commit from the
  copy. When that fails, what it left is removed and the download goes on
  with the repository's URL and the fallbacks (substitutes of the
  checkout, Software Heritage), as without a cache. A transfer from the
  copy that stalls is given up. A submodule is fetched from the URL that
  the repository records: an absolute URL is the submodule's own
  repository, not a copy; a relative URL is resolved against the copy's
  address, so it names the copy of the submodule's repository.
- A checkout made by the `guix` command (`update-cached-checkout`) that
  does not exist yet is cloned from the copy; one that exists fetches the
  copy's branches and tags, unless the commit or tag it is asked for is
  there already. Then the checkout goes on as without a cache: the
  repository is asked when what is asked for is a branch or is still
  missing. When that fails after the copy has been fetched, a warning is
  printed and what the copy gave is used. When the copy cannot be had, the
  checkout is cloned or fetched from the repository, as without a cache.
  Submodules are fetched from their own URLs.

Everything recorded names the repository, never the copy: the checkout's
directory, its remote `origin`, the URL that commands print and write.

## What a cache answers for a Git repository

A read-only Git repository served over Git's smart HTTP protocol that has
the branches and tags of the repository it copies. A cache that copies a
repository on demand fetches from the repository before it advertises the
copy's references, so that the copy is as recent as the repository:
`guix pull` refuses a commit older than the one it has. When the
repository does not answer, it advertises what it has. When it has no copy
and cannot make one, any status other than `200` lets the client go to the
repository.

## Trust

The daemon checks the hash of a fixed-output derivation's result whatever
its source, so a cache cannot make a build accept a different file or
checkout. A checkout made by the `guix` command goes through the same
commit checks and channel authentication with or without a copy, and a
copy that is older than the repository loses to the repository when the
repository answers. The cache does not need TLS or a key.

## What it does not cover

Substitutes are not downloads of this kind: a cache for them is one more
entry in the daemon's `--substitute-urls`. Git repositories reached
through another protocol than HTTP or HTTPS are not asked from the cache,
and neither are listings of a repository's references
(`remote-refs`, used by `guix refresh`). A builder that fetches from the
network itself is not affected.

The code is `(guix download-cache)` and `(guix download-cache git)`. The
hooks are a few lines in `guix/scripts/perform-download.scm` and in
`update-cached-checkout` in `guix/git.scm`. `tests/download-cache.scm` runs
the download program against a stand-in cache and checks out repositories
from stand-in copies.

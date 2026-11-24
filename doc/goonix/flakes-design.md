# Flakes for goonix: design note

Status: the first design, kept for its reasoning. What the code does, and
where it departs from this note, is in [`flakes.md`](flakes.md).

This note describes a Guix-native counterpart of Nix flakes for goonix: a
project declares what it depends on and what it provides in one Scheme
file, and a lock file pins every dependency to an exact commit and content
hash. It is written so that the work can be picked up phase by phase.

## 1. The problem

Guix already has the pieces of a reproducible project setup, but they are
separate, user-global, and none of them is locked by default:

| Need | What Guix has today | What is missing |
|---|---|---|
| Pin Guix itself | `channels.scm` with `(commit …)`, used through `guix time-machine -C` or `guix pull -C` | Written by hand (`guix describe -f channels`); no content hash; lives outside the commands that use it |
| Pin other inputs (a source tree, another project) | `origin` records with hashes inside package definitions; channels for Scheme code | No project-level inputs; no way to say "that repository at a locked commit" |
| Declare what a project provides | `guix.scm` (one package), `manifest.scm` (one profile), an OS file, a `guix home` file, a `guix deploy` file | One file per command, each with its own conventions; nothing lists them |
| Evaluate hermetically | — | Evaluation sees the user's channels, `GUILE_LOAD_PATH`, `-L` flags and `~/.config/guix` |
| One addressing scheme | file names and `-e` expressions | No `project#output` form |

The result is that "build this system image" is really "build it with
whatever Guix is first in `PATH`, plus whatever channels this user pulled".
Reproducing someone else's build means reconstructing their `guix describe`.

## 2. Goals and non-goals

Goals:

1. One file, `flake.scm`, at the root of a project declares inputs and
   outputs.
2. One generated file, `guix.lock`, pins every input, transitively, to a
   commit and a content hash. Commands never resolve a branch name when a
   lock exists.
3. Evaluation depends only on the flake, its lock, and the system type.
4. Every command that takes a file or a package name also takes a flake
   reference: `guix build .#hello`, `guix system image .#hurd64`,
   `guix shell .#dev`, `guix deploy .#fleet`.
5. Existing projects keep working. A repository with only `guix.scm` or
   `manifest.scm` is usable as a flake without changes.

Non-goals:

- Replacing channels as the way Guix itself is distributed. A flake input
  of type `channel` wraps a channel; `guix pull` stays.
- Compatibility with Nix's `flake.nix` or its lock format.
- A registry of short names. References are URLs or paths. (A registry can
  be added later without changing anything below.)

## 3. `flake.scm`

A flake is a Scheme file whose value is a `<flake>` record.

```scheme
(use-modules (guix flakes))

(flake
 (description "GNU/Hurd images for hurdkit")

 (inputs
  (list
   ;; The Guix (here: goonix) that evaluates the outputs.
   (flake-input
    (name 'guix)
    (type 'channel)
    (url "https://github.com/hurdkit/goonix")
    (branch "goonix"))
   ;; Another flake. Its outputs become available under `inputs`.
   (flake-input
    (name 'toolchain)
    (type 'flake)
    (url "https://github.com/hurdkit/hurdkit")
    (branch "main"))
   ;; A plain source tree: not evaluated, only fetched.
   (flake-input
    (name 'ninepfs)
    (type 'source)
    (url "https://github.com/bugaevc/9pfs")
    (branch "master"))))

 (outputs
  (lambda (inputs system)
    (flake-outputs
     (packages
      `((hello . ,(specification->package "hello"))))
     (systems
      `((hurd64 . ,(load "guix/hurd64.scm"))))
     (images
      `((hurd64 . ,(image-with-os hurd64-qcow2 (load "guix/hurd64.scm")))))
     (shells
      `((dev . ,(specifications->manifest '("qemu" "openssh")))))
     (machines
      `((fleet . ,(load "guix/deploy.scm"))))
     (default 'hurd64)))))
```

Rules:

- `inputs` is data. It must be readable without evaluating `outputs`, so
  that locking does not run project code.
- `outputs` is a procedure of two arguments: an association list from input
  name to resolved input, and the system string. It must not read the
  environment, the clock, or files outside the flake's own tree and its
  inputs.
- Output kinds are fixed (`packages`, `systems`, `images`, `homes`,
  `shells`, `machines`, `channels`, `default`). Each kind corresponds to an
  existing command, so no new evaluation machinery is needed.
- `(load "file")` inside `outputs` is resolved relative to the flake root
  and refuses to leave it.

### Input types

| `type` | What is fetched | What `inputs` contains |
|---|---|---|
| `channel` | a git repository that is a Guix channel | the channel; contributes modules to the load path, like `-L` |
| `flake` | a git repository or directory with a `flake.scm` | that flake's evaluated outputs |
| `source` | a git repository, a tarball URL, or a local directory | a file-like object for the tree (usable as a package `source`) |

The input named `guix` is special: it is the Guix that evaluates
`outputs`. If it is absent, the running Guix is used and recorded in the
lock, so that the build is still pinned.

## 4. `guix.lock`

Generated, committed to version control, never edited by hand. An
S-expression, so that it can be read with `read` and no code is evaluated:

```scheme
(flake-lock
 (version 1)
 (inputs
  ((guix
    (type channel)
    (url "https://github.com/hurdkit/goonix")
    (branch "goonix")
    (commit "…40 hex digits…")
    (nar-sha256 "…nix-base32…"))
   (toolchain
    (type flake)
    (url "https://github.com/hurdkit/hurdkit")
    (branch "main")
    (commit "…")
    (nar-sha256 "…")
    (inputs ((guix (follows guix)))))   ; transitive inputs, flattened or "follows"
   (ninepfs
    (type source)
    (url "https://github.com/bugaevc/9pfs")
    (branch "master")
    (commit "…")
    (nar-sha256 "…")))))
```

- `commit` makes the fetch exact; `nar-sha256` (the hash of the checked-out
  tree, as `guix hash -rx` prints it) makes it verifiable and lets the tree
  be fetched as a fixed-output derivation, hence substituted or mirrored.
- A lock entry is valid as long as `type`, `url` and `branch` in
  `flake.scm` are unchanged. If they changed, the input is re-locked.
- Transitive inputs are recorded. `(follows NAME)` makes a dependency's
  input use the top-level input of that name, which is how a whole tree is
  made to share one Guix.

## 5. Commands

```
guix flake init                 write a template flake.scm
guix flake lock                 create guix.lock entries that are missing
guix flake update [INPUT…]      move the named inputs (or all) to their branch heads
guix flake show [REF]           list outputs
guix flake metadata [REF]       print inputs with locked commits and dates
guix flake check [REF]          evaluate every output; build nothing
```

Flake references, accepted wherever a file or package name is today:

```
.#hurd64                          this directory (or an ancestor) and output hurd64
/path/to/project#hurd64
https://example.org/repo.git#hurd64
https://example.org/repo.git?ref=v1.2#hurd64
```

Mapping to existing commands:

| Command | Flake form | Reads output kind |
|---|---|---|
| `guix build` | `guix build .#hello` | `packages` |
| `guix shell` | `guix shell .#dev` | `shells` (manifest) or `packages` (with `-D`) |
| `guix system build/image/vm/reconfigure` | `guix system image .#hurd64` | `images`, then `systems` |
| `guix home` | `guix home reconfigure .#me` | `homes` |
| `guix deploy` | `guix deploy .#fleet` | `machines` |
| `guix pull` | `guix pull --flake=.` | the locked `guix` input and `channels` |

A command given a flake reference never updates the lock. If an input is
unlocked it stops with "run `guix flake lock`"; `--no-lock-check` is not
offered.

## 6. Evaluation

Two cases, decided by the locked `guix` input.

**The locked Guix is the running Guix** (same commit): load `flake.scm` in
the current process, with the load path reduced to the running Guix plus
the `channel` inputs.

**It is a different commit**: re-execute, exactly as `guix time-machine`
does. `(guix scripts time-machine)` already calls `cached-channel-instance`
from `(guix inferior)` to build (or fetch) the requested Guix and then
`execl`s its `guix` binary with the original command line. The flake
command does the same with the channel list computed from the lock instead
of from `-C channels.scm`. This reuses the cache in
`~/.cache/guix/inferiors` and the existing forward-update and
authentication checks.

Hermeticity, enforced in the process that evaluates `outputs`:

- `GUILE_LOAD_PATH`, `GUILE_LOAD_COMPILED_PATH` and `GUIX_PACKAGE_PATH` are
  reset to the locked Guix and the `channel` inputs.
- `~/.config/guix/channels.scm` and `-L` are ignored (with a warning if
  `-L` was given).
- `%current-system` / `%current-target-system` come from the command line
  only.

Fetching inputs uses what is already there: `update-cached-checkout` and
`latest-repository-commit` in `(guix git)` for git, the cache under
`~/.cache/guix/checkouts`, and `(guix channels)` (`latest-channel-instances`,
`channel-instances->derivation`) for `channel` inputs.

## 7. Authentication and trust

- `channel` inputs keep channel authentication: if the `flake-input` has an
  `introduction`, `authenticate-channel` runs as it does for `guix pull`.
- goonix itself cannot be authenticated that way (its commits are not
  signed by keys in `.guix-authorizations`). For such inputs the lock's
  `nar-sha256` is the integrity check, and an input without an introduction
  is reported as "unauthenticated, pinned by hash" in `guix flake metadata`.
- Evaluating `outputs` runs code from the project. `guix shell` already has
  a consent mechanism for `guix.scm`/`manifest.scm`
  (`~/.config/guix/shell-authorized-directories`); flake evaluation of a
  local directory uses the same list. Remote references given explicitly on
  the command line count as consent.

## 8. Compatibility

- A directory with no `flake.scm` but with `guix.scm` and/or `manifest.scm`
  is an implicit flake: `packages.default` from `guix.scm`, `shells.default`
  from `manifest.scm`, the running Guix as the `guix` input.
- `guix flake lock --export-channels` writes the locked `channel` inputs as
  a `channels.scm`, for users of upstream Guix.
- `guix flake init --from-channels=FILE` turns an existing `channels.scm`
  into the `inputs` of a new `flake.scm`.

## 9. Implementation phases

Each phase is useful on its own and is tested before the next one starts.
All new code goes into new files (see `GOONIX.md`, "add files").

| Phase | Deliverable | New files | Done when |
|---|---|---|---|
| 1 | Records and readers: `<flake>`, `<flake-input>`, `<flake-outputs>`; read `flake.scm` inputs without evaluating outputs; read/write `guix.lock` | `guix/flakes.scm`, `tests/flakes.scm` | round-trip tests for the lock pass; a malformed lock is rejected with the file and line |
| 2 | Locking: `guix flake lock`, `update`, `metadata`; git and directory inputs; `nar-sha256` computed and verified | `guix/scripts/flake.scm` | locking twice is a no-op; changing a URL re-locks only that input; a tampered checkout fails verification |
| 3 | Evaluation in the running Guix: `guix flake show`, `check`; `guix build .#x` | `guix/flakes/eval.scm`, edits to `guix/scripts/build.scm` | an output builds to the same derivation as the equivalent `-f`/`-e` invocation |
| 4 | Re-execution under the locked `guix` input, through `cached-channel-instance` | edits to `guix/scripts/flake.scm` | with a lock naming another commit, `guix --version` inside the evaluation is that commit |
| 5 | Remaining commands: `shell`, `system`, `home`, `deploy` accept references | small edits in each script | each has one test building from a reference |
| 6 | `type 'flake` inputs, `follows`, transitive lock | `guix/flakes.scm` | a two-level example locks and evaluates; a cycle is reported, not looped on |
| 7 | Implicit flakes, `--export-channels`, `--from-channels`; manual chapter | `doc/goonix/flakes.texi` | the compatibility cases in section 8 are tested |

Phases 3 and 5 edit upstream files (`guix/scripts/*.scm`). Keep those edits
to the option parser and one dispatch call each, so that merges from
upstream stay small.

## 10. Open questions

1. **Lock format: S-expression or JSON?** S-expression is proposed (no new
   dependency, `read` is safe). JSON would be readable by non-Guile tools.
2. **Should `outputs` receive `system`, or use `%current-system`?** An
   explicit argument is proposed: it makes cross-compilation outputs
   (`x86_64-gnu` images built on `x86_64-linux`) expressible without
   parameterizing.
3. **Where does the Nix flake of goonix fit?** For now the Nix flake pins
   goonix, and a `flake.scm` would pin everything Guix-side. Once phase 4
   exists, a project needs only *some* goonix to start with, and the lock
   takes over, as `guix time-machine` does today.
4. **Tarball inputs** have no commit; they are locked by URL and hash only.
   Is `guix flake update` allowed to re-download and change the hash, or
   must the URL change?

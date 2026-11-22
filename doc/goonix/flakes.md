# Flakes

A flake is a directory with a `flake.scm`. The file names what the project
is made from (its inputs), and has one procedure that says what the project
provides (its outputs). `guix.lock` pins every input, transitively.

The first design is in `flakes-design.md`; this file describes what the code
does. Pure evaluation of ordinary files is in `pure-evaluation.md`.

## The file

```scheme
(flake
 (format 1)
 (description "Images and their tests")
 (modules "scheme")                     ; where this tree keeps its modules

 (inputs
  (guix    (git "https://example.org/guix") (branch "main"))
  (tools   (git "https://example.org/tools"))
  (kernel  (git "https://example.org/kernel") (tag "v6") (as source))
  (helpers (local "../helpers") (as library)))

 (options
  (graphics? boolean #f "Include the graphics stack"))

 (outputs
  (lambda (in)
    (use-modules (gnu) (my images))
    `((packages (default . ,(input-output in 'tools 'packages 'default)))
      (images   (disk . ,(disk-image #:graphics? (option in 'graphics?))))
      (shells   (default . ,(shell (packages (list hello)))))))))
```

The host reads this file; it does not load it. Everything but `outputs` is
data, and `outputs` runs only in the evaluator (below). The reader accepts
G-expression syntax (`#~`, `#$`, `#+`) and no other reader extension.

### Inputs

`(NAME SOURCE FIELD...)`, where the source is `(git "URL")` or
`(local "PATH")`. A relative path is relative to the flake.

| Field | Meaning |
|---|---|
| `(branch "B")`, `(tag "T")`, `(commit "C")` | what to take; the default branch otherwise |
| `(as flake)`, `(as library)`, `(as source)` | what the input is used as. Unsaid, the tree decides: `flake` with a `flake.scm`, `library` with only a `.guix-channel`; a tree with neither must say |
| `(worktree)` | for a local input: the tracked files as they are, instead of a commit |
| `(pinned)` | the input keeps its own `guix.lock` for everything below it |
| `(inputs (THEIRS follows OURS) (THEIRS SOURCE FIELD...))` | point an input of the input at one of ours, or replace it |
| `(options (NAME VALUE) ...)` | set options of the input's flake |
| `(introduction (commit "C") (signer "FINGERPRINT"))` | authenticate the history from that commit, as for a channel |
| `(same-as "PATH-OR-URL" NAME)` | in place of a source: take the pin of NAME from that flake's lock |

A `flake` input gives handles to its outputs (`input-output`). A `library`
input puts its Scheme modules on the load path of this flake; the
dependencies in its `.guix-channel` become its inputs. A `source` input is
a directory (`input-source`).

The input named `guix` is the Guix that evaluates the flake. A flake
without one is evaluated by the Guix that runs the command.

### Outputs

`outputs` takes the evaluation context and returns an alist of kinds, each an
alist of names and values. Its body may begin with `(use-modules ...)`.

| In the body | Gives |
|---|---|
| `(system in)`, `(target in)` | the system, and the cross target or `#f` |
| `(option in 'NAME)` | the value of an option |
| `(input-source in 'NAME)` | the tree of an input, a directory in the store |
| `(input-output in 'NAME 'KIND 'OUTPUT)` | a handle to an output of a flake input; it can be an input of a package, appear in a G-expression, and become a manifest entry with `input-handle->manifest-entry` |
| `(self-file in "FILE")` | a file of this flake's tree |
| `(source-set in "FILE" ...)` | a store item with these files of the tree and no others |
| `(self-revision in)` | the commit of the tree, or `#f` when it has changes |
| `(shell (packages ...) (inputs-from ...) (environment ...))` | what `guix shell` enters |
| `(override ORIGINAL REPLACEMENT)` | an entry of the `overrides` kind |

| Kind | Value | Used by |
|---|---|---|
| `packages` | a package or another file-like object | `guix build DIR#NAME`, `guix shell DIR#NAME` |
| `shells` | a shell, a manifest or a package | `guix shell` (`default`), `guix shell DIR#NAME` |
| `systems`, `images` | an operating system, an image | `guix system ACTION DIR#NAME` |
| `homes` | a home environment | `guix home ACTION DIR#NAME` |
| `machines` | a machine or a list of machines | `guix deploy DIR#NAME` |
| `apps` | a program | `guix run DIR#NAME` (falls back to `packages`) |
| `checks` | anything that builds | `guix flake check` |
| `overrides` | overrides | every lowering of this evaluation |
| anything else | anything | listed by `guix flake show` |

An override replaces one package object by another wherever the first is
lowered in the evaluation. Nothing is rewritten ahead of time, and while a
replacement is lowered what it replaces stays itself, so a replacement can
wrap its original. Overrides need goonix as the `guix` input: the mechanism
is three hooks in `(guix packages)` and the module
`(guix package-overrides)`.

## The lock

`guix.lock` is a graph. A node is a tree: where it comes from, the commit,
the NAR SHA-256 of its tracked files, and whether its history was
authenticated. An edge is an input of a flake: its name, the node, what it
is used as, its options, and why it points there (`direct`, `followed`,
`pinned`, `replaced`, `same-as`).

- An input of an input that comes from the same repository as an input of
  the flake follows it: the edge leads to the flake's node. A project has
  one copy of a shared dependency, and one Guix, unless it says otherwise.
  When several inputs of the flake come from that repository, the one of
  the same name is followed, else none.
- `(pinned)` copies the graph of the input's own lock, without fetching.
- Locking fetches and reads; it evaluates nothing. An input whose
  declaration has not changed keeps its commit, and its tree must still
  have the recorded hash. `guix flake update` resolves anew.
- A local input is recorded relative to the flake when it lies inside it.
  It means the commit, whatever the directory holds; with `(worktree)` it
  means the tracked files as they are, and no hash is recorded. Commands
  say in one line when a checkout has moved or has changes.
- `flake.local.scm`, not committed, redirects inputs on this machine:
  `(flake-local (version 1) (inputs (NAME SOURCE FIELD...) ...))`.
  `--override-input=NAME=SPEC` does the same for one run; SPEC is a path or
  the fields of an input. The lock that results is kept in the cache
  directory; `guix.lock` is not touched. What the flake says about the
  input, and what follows it, stays.

## Evaluation

Each flake is evaluated in a process of its own, in the container of
`pure-evaluation.md`: it sees the store, the daemon's socket and an empty
`/tmp`. All trees are store items. The host sends one request and answers
the evaluator's questions; derivation file names and plain data come back.

- With a `guix` input, that commit is built with the library inputs as its
  channels, the way `guix time-machine` builds one, and it runs
  `guix repl` on the evaluator module, which the host hands it as source.
  It must report the pinned commit.
- A flake input is evaluated by its own evaluator, with the edges the lock
  has for it; when it is pinned, by its own Guix.
- Evaluations are cached under the lock in effect, the tree, the Guix, the
  system, the target, the options and what was asked. The derivations are
  kept by collector roots. A hit starts no evaluator.

## Commands

`guix flake lock`, `update [INPUT]...`, `metadata`, `show`, `check
[--reproducible]`, `init`; `-C DIR` names the flake.

`guix build`, `guix shell`, `guix system`, `guix home`, `guix deploy` and
`guix run` take `DIRECTORY#NAME` where they take a file or a package, and
with it `--option=NAME=VALUE` and `--override-input=NAME=SPEC`.

For `guix system`, `guix home` and `guix deploy` the evaluator runs the
command itself, with the output in the place of the file, as far as the
derivations. An action that only builds is then built by the host. An
action that changes a machine (`reconfigure`, `init`, `deploy`) runs the
same program a second time outside the container; it computes the
derivations again and goes on only if they are those the container
computed.

## Not there

- References by URL (`URL#NAME`), templates (`guix flake init -t`), the
  user's default flake and the conversion to and from channel files.
- A directory with only `guix.scm` or `manifest.scm` is not treated as a
  flake; `--pure-eval` covers that case.
- Library inputs are compiled only as channels of a `guix` input; without
  one, and for work trees, their modules are interpreted.

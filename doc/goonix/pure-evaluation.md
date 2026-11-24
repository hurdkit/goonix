# Pure evaluation

`--pure-eval` makes a command evaluate its files, expressions and package
names in a container. The result of the evaluation is a set of derivations;
the command then builds them and goes on as usual. It is accepted by

- `guix build`, for everything the command line names (`-f`, `-m`, `-e`,
  `-D`, `-S`, package names, transformation options);
- `guix shell`, likewise, including a `guix.scm` or `manifest.scm` found
  without `-f`;
- `guix system` for the actions that only build (`build`, `image`, `vm`,
  `container`, `docker-image`).

`guix system init` and `guix system reconfigure` act on the machine and are
refused with `--pure-eval`.

The code is in `guix/pure-eval.scm`. Each command has one hook that hands
its parsed options to that module.

## What the evaluator sees

The evaluator is a new Guile process in its own user, mount, PID, IPC, UTS
and network namespaces. It is given:

| Thing | State |
|---|---|
| The store | read-only |
| The build daemon's socket | as outside; builds that evaluation asks for go through the daemon |
| The files Git tracks in each project | read-only, at the place where the work tree is |
| The modules of Guix | read-only |
| `/tmp` | empty, writable |
| Environment | `HOME=/tmp`, `TMPDIR=/tmp`, the load paths below, the store directory and the daemon socket; nothing of the caller's |
| Network | none, not even loopback |
| Host name | `localhost` |
| Clock, `/dev/urandom` | the host's; not controlled |

A *project* is the Git work tree that holds a file named with `-f` or `-m`
(or the file argument of `guix system`), or a directory named with `-L`.
With `-e`, the work tree of the current directory is a project too, so that
the expression can name files relative to it. The tracked files are those
in Git's index, with the contents they have in the work tree: a file must
be added, it need not be committed. The path of a submodule is an empty
directory.

Because each project is mounted where its work tree is, every file name on
the command line and in the code means inside what it means outside.
Untracked and ignored files do not exist there.

A file that is in no Git checkout is an error. A `-L` directory that is in
no checkout is left out with a warning. Directories that come from
`GUIX_PACKAGE_PATH` or `GUILE_LOAD_PATH` are left out unless they lie inside
a project.

## What comes back

One datum, on a pipe of its own: the file names of the derivations. What
the evaluated code prints goes to standard error and cannot be taken for
the result. Errors are reported by the evaluator in the command's usual
form, followed by one line from the command saying that the evaluation
failed.

A file whose evaluation does not depend on what the container hides gives
the same derivation with and without `--pure-eval`.

## Limits

- `guix system vm --pure-eval` gives a script without `-enable-kvm`: the
  ordinary evaluation looks for `/dev/kvm` on the host, which the container
  does not show.
- A daemon reached over the network (`GUIX_DAEMON_SOCKET=ssh://…` or
  `guix://…`) cannot be used.
- Options whose value cannot be written and read back, such as `--share`
  and `--expose` of `guix system`, are refused together with `--pure-eval`.
- When Guix runs from a checkout (`./pre-inst-env`), the `guix` and `gnu`
  directories of that checkout are mounted read-only, and nothing else of
  it.
- Two projects of which one lies inside the other cannot both be shown.

## Where no container can be made

Without unprivileged user namespaces (the Hurd), or when the Guile that
runs Guix is not in a store item, the evaluator runs on the host's file
system with the same scrubbed environment, and a warning says so. Files
outside the projects are readable in that case.

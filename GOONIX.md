# goonix

goonix is a fork of [GNU Guix](https://guix.gnu.org). It is not affiliated
with, or endorsed by, the GNU Guix project. The upstream `README` is kept
unchanged next to this file.

| | |
|---|---|
| Upstream | `https://codeberg.org/guix/guix.git`, branch `master` |
| Fork point | commit `fd49d69fbe07557f0bf55bc7e556e60fc5b13082` (2026-11-11), Guix 1.5.0 development series |
| Our branch | `goonix`: the fork point plus our commits |
| `main` | a mirror of upstream `master`, without our commits |
| Licence | GPL-3.0-or-later, unchanged (see `COPYING`) |

## Why it exists

1. **Pin Guix with a lock file instead of channels.** Upstream Guix is
   delivered by `guix pull` from channels. Here the tree is built by Nix
   from a flake, so a consumer pins one exact commit of goonix in its own
   `flake.lock` and gets the `guix` command of that commit. No `guix pull`,
   no `channels.scm`, no `guix time-machine`.
2. **A place to change Guix itself.** What it changes is described in
   `doc/goonix/`: evaluation in a container
   ([`pure-evaluation.md`](doc/goonix/pure-evaluation.md)), a Guix-native
   equivalent of flakes ([`flakes.md`](doc/goonix/flakes.md); the first
   design is in [`flakes-design.md`](doc/goonix/flakes-design.md)), and a
   content-addressed store
   ([`content-addressing.md`](doc/goonix/content-addressing.md)).

## Using it

A running Guix build daemon is required; goonix provides the client and the
daemon program, not the system service. On NixOS:

```nix
services.guix.enable = true;
```

Build and run the fork:

```sh
nix build github:hurdkit/goonix/goonix        # ./result/bin/guix
nix run   github:hurdkit/goonix/goonix -- --version
```

Pin it from another flake:

```nix
{
  inputs.goonix.url = "github:hurdkit/goonix/goonix";

  outputs = { self, nixpkgs, goonix }: {
    devShells.x86_64-linux.default =
      nixpkgs.legacyPackages.x86_64-linux.mkShell {
        packages = [ goonix.packages.x86_64-linux.default ];
      };
  };
}
```

`nix flake update goonix` in that flake moves the pin; nothing else does.

To run the daemon from the fork as well (optional; a daemon from upstream
Guix serves a goonix client fine):

```nix
nixpkgs.overlays = [ inputs.goonix.overlays.default ];
services.guix.package = pkgs.goonix;
```

The command is still called `guix` and the store is still `/gnu/store`.
Both are deliberate: see the next section.

## Substitutes, and the rule that follows from them

Whether a package can be downloaded pre-built depends only on its
derivation, and the derivation depends only on the package definitions in
this tree. How the `guix` command itself was built (Nix here, `guix pull`
upstream) does not matter. So:

- Every package whose definition is identical to upstream at a commit the
  upstream build farm built is still substitutable from
  `ci.guix.gnu.org` / `bordeaux.guix.gnu.org`.
- Editing a package definition under `gnu/packages/` changes the derivation
  of that package **and of everything that depends on it**. Those are then
  built locally. A change to a low-level package (glibc, gcc, guile) means
  rebuilding the world.

The rule: **add files; do not edit upstream files unless the change is the
point.** New commands, modules and documents go into new files. This also
keeps merges from upstream free of conflicts.

## Working on the tree

```sh
nix develop                # build dependencies of Guix
./bootstrap
./configure --localstatedir=/var --sysconfdir=/etc
make -j"$(nproc)"
./pre-inst-env guix --version
```

`--localstatedir=/var` is not optional: without it the build looks for the
daemon socket and the store database under `/usr/local/var` and cannot talk
to the system daemon.

`nix build` does not use the working directory of a git checkout but the
files git knows about: `git add` a new file before building, or it is
missing from the build.

## Merging from upstream

`main` follows upstream; our work is on `goonix`, which merges `main`:

```sh
git remote add upstream https://codeberg.org/guix/guix.git   # once
git fetch upstream master
git push origin upstream/master:main    # main mirrors upstream
git checkout goonix
git merge upstream/master
```

Prefer merging a commit that the upstream build farm has finished building
(its evaluations are listed at `https://ci.guix.gnu.org`); the substitutes
for exactly that commit then exist. Fetch with `git`, do not scrape the web
interface.

## What does not work, by design

- **`guix pull` from this repository.** Channel authentication requires
  every commit to be signed by a key listed in `.guix-authorizations`.
  Commits made here are not, so `guix pull` rejects the channel. Pin the
  flake instead. (`guix pull` without arguments would fetch upstream Guix
  and put it in front of this build in `PATH`; do not run it if you mean to
  use the fork.)
- **`guix describe`** reports no channels: this build has no channel
  metadata. `guix --version` shows the base version and the goonix commit.

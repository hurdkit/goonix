{
  description = "goonix: a fork of GNU Guix, built and pinned with Nix flakes";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The commit this tree was built from. A flake source has no .git
      # directory, so the build cannot ask git; the revision is written into
      # .tarball-version instead, which is what `guix --version` reports.
      rev = self.shortRev or self.dirtyShortRev or "unknown";

      # The version of upstream Guix this fork is based on (see NEWS).
      baseVersion = "1.5.0";

      # The recipe is the one nixpkgs uses for Guix: an ordinary autotools
      # build against Guile and the guile-* libraries of nixpkgs. Only the
      # source is replaced, by this checkout. The command keeps the name
      # `guix`, and the store stays /gnu/store, so that substitutes built by
      # the upstream build farms remain usable for every package this fork
      # does not change.
      mkGoonix =
        pkgs:
        pkgs.guix.overrideAttrs (old: {
          pname = "goonix";
          version = "${baseVersion}-goonix.${rev}";
          src = self;

          # goonix: the optional CA decoder is a separate helper program.
          buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.libarchive ];

          meta = old.meta // {
            description = "Fork of GNU Guix, a functional package manager with a Scheme interface";
            homepage = "https://github.com/hurdkit/goonix";
            changelog = "https://github.com/hurdkit/goonix/blob/goonix/NEWS";
            maintainers = [ ];
          };
        });
    in
    {
      packages = forAllSystems (pkgs: rec {
        goonix = mkGoonix pkgs;
        default = goonix;
      });

      # Adds `pkgs.goonix`. On NixOS, the daemon can then be switched to the
      # fork with `services.guix.package = pkgs.goonix;`.
      overlays.default = final: prev: { goonix = mkGoonix prev; };

      # Everything needed to build the checkout by hand:
      #   ./bootstrap && ./configure --localstatedir=/var --sysconfdir=/etc && make
      #   ./pre-inst-env guix ...
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ (mkGoonix pkgs) ];
          packages = [ pkgs.age pkgs.openssh ];

          # The bootstrap Guile 2.0 scripts in tests/gexp.scm must not load
          # Guile 3.0's own ice-9/boot-9.go.  Keep the Guile libraries'
          # compiled paths, but remove only the interpreter's private cache.
          shellHook = ''
            # The real-hold two-store fixture needs a static sleep applet.
            # Use this flake's locked nixpkgs, never a channel or NIX_PATH.
            export GOONIX_SLEEP_SOURCE=${pkgs.pkgsStatic.busybox}/bin/busybox
            goonix_guile=${pkgs.guile}
            GUILE_LOAD_COMPILED_PATH=$(IFS=:
              result=
              for path in ''${GUILE_LOAD_COMPILED_PATH-}; do
                if [ "$path" != "$goonix_guile/lib/guile/3.0/ccache" ]; then
                  result=''${result:+$result:}$path
                fi
              done
              printf '%s' "$result")
            export GUILE_LOAD_COMPILED_PATH
            unset goonix_guile
          '';
        };
      });
    };
}

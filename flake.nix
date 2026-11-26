{
  description = "goonix: a fork of GNU Guix, built and pinned with Nix flakes";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # goonix: the daemon is also a haskell-flake project.
  inputs.flake-parts.url = "github:hercules-ci/flake-parts";
  inputs.haskell-flake.url = "github:srid/haskell-flake";

  outputs =
    inputs@{ self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      rev = self.shortRev or self.dirtyShortRev or "unknown";
      baseVersion = "1.5.0";

      # The commit is recorded because a flake source has no .git directory.
      # The default package ships the Haskell daemon (HS-8 switch 1); the C++
      # daemon stays available as goonix-cxx-daemon below.
      mkGoonix = pkgs:
        pkgs.guix.overrideAttrs (old: {
          pname = "goonix";
          version = "${baseVersion}-goonix.${rev}";
          src = self;
          # goonix: the optional CA decoder is a separate helper program.
          buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.libarchive ];

          # goonix: the daemon choice is explicit, not configure's auto probe.
          nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.haskell.packages.ghc910.ghc ];
          configureFlags = (old.configureFlags or []) ++ [ "--enable-haskell-daemon" ];
          meta = old.meta // {
            description = "Fork of GNU Guix, a functional package manager with a Scheme interface";
            homepage = "https://github.com/hurdkit/goonix";
            changelog = "https://github.com/hurdkit/goonix/blob/goonix/NEWS";
            maintainers = [ ];
          };
        });

      # goonix: compose the ordinary package with the standalone daemon project.
      composed = inputs.flake-parts.lib.mkFlake { inherit inputs; } {
        systems = systems;
        imports = [ inputs.haskell-flake.flakeModule ];
        perSystem = { system, config, ... }: {
          config = {
          haskellProjects.default = {
            basePackages = nixpkgs.legacyPackages.${system}.haskell.packages.ghc910;
            projectRoot = ./daemon;
            packages.guix-daemon-hs.source = ./daemon;
            # gcrypt is the C library used by libutil/hash.cc, not Hackage.
            otherOverlays = [
              (self: super: {
                gcrypt = nixpkgs.legacyPackages.${system}.libgcrypt;
                sqlite = nixpkgs.legacyPackages.${system}.sqlite.out;
                sqlite3 = nixpkgs.legacyPackages.${system}.sqlite.out;
              })
            ];
            settings.guix-daemon-hs = {
              # These suites need the external store vectors and proxy path.
              # They are run explicitly, not by the package's generic checkPhase.
              check = false;
              drvAttrs = {
                nativeBuildInputs = [ nixpkgs.legacyPackages.${system}.guile nixpkgs.legacyPackages.${system}.gcc ];
                postInstall = ''
                  # goonix: the out-of-process CA decoder ships in libexec, as in
                  # the make build (daemon/local.mk).  The daemon's default helper
                  # path is the make-expanded libexecdir (Goonix.Config).  The
                  # libutil sources include config.h; the Cabal build has no
                  # configure run, so provide the few macros they read.
                  mkdir -p $out/libexec ca-scan-build
                  printf '%s\n' \
                    '#define HAVE_SCHED_H 1' \
                    '#define HAVE_SCHED_SETAFFINITY 1' \
                    '#define HAVE_STATX 1' \
                    '#define HAVE_CLOSE_RANGE 1' \
                    '#define HAVE_LINUX_CLOSE_RANGE_H 1' \
                    '#define HAVE_STRSIGNAL 1' \
                    '#define HAVE_POSIX_FALLOCATE 1' \
                    > ca-scan-build/config.h
                  g++ -O2 -std=c++20 -DHAVE_CONFIG_H \
                    -Ica-scan-build -I${./nix/libutil} \
                    ${./nix/goonix-ca-scan.cc} ${./nix/libutil/util.cc} \
                    ${./nix/libutil/affinity.cc} \
                    -lz -larchive -o $out/libexec/goonix-ca-scan
                  gcc -O2 -c ${./daemon/cbits/helpers.c} -o sandbox-helpers.o
                  g++ -O2 -std=c++17 ${./daemon/sandbox/guix-sandbox.cc} \
                    sandbox-helpers.o -o $out/bin/guix-sandbox
                '';
                preConfigure = ''
                  mkdir -p src/Goonix
                  guile --no-auto-compile make-config.scm \
                    src/Goonix/Config.hs /gnu/store /var/guix /var/log/guix \
                    /etc/guix /bin /libexec /share/locale x86_64-linux \
                    'https://bordeaux.guix.gnu.org https://ci.guix.gnu.org' \
                    ${./guix/store/schema.sql}
                '';
              };
              librarySystemDepends = [
                nixpkgs.legacyPackages.${system}.libgcrypt
                nixpkgs.legacyPackages.${system}.sqlite
                nixpkgs.legacyPackages.${system}.zlib
                nixpkgs.legacyPackages.${system}.bzip2
                nixpkgs.legacyPackages.${system}.libarchive
              ];
            };
            autoWire = [ ];
            devShell = {
              extraLibraries = hp: {
                gcrypt = nixpkgs.legacyPackages.${system}.libgcrypt;
                sqlite = nixpkgs.legacyPackages.${system}.sqlite.out;
                sqlite3 = nixpkgs.legacyPackages.${system}.sqlite.out;
              };
              hoogle = false;
              tools = hp: {
                haskell-language-server = null;
                hlint = null;
                ormolu = null;
                ghcid = null;
              };
              mkShellArgs.nativeBuildInputs = [
                nixpkgs.legacyPackages.${system}.cabal-install
              ];
            };
          };
            packages.guix-daemon-hs = config.haskellProjects.default.outputs.packages.guix-daemon-hs.package;
            devShells.daemon = config.haskellProjects.default.outputs.devShell;
          };
        };
      };
    in
    lib.recursiveUpdate composed {
      packages = forAllSystems (pkgs: rec {
        goonix = mkGoonix pkgs;
        default = goonix;
        goonix-cxx-daemon = goonix.overrideAttrs (old: {
          configureFlags = old.configureFlags ++ [ "--disable-haskell-daemon" ];
        });
      });
      overlays.default = final: prev: { goonix = mkGoonix prev; };
      checks = forAllSystems (pkgs:
        let
          # The VM test script lives in daemon/test, a tracked file of self.
          # mkGoonix uses src = self, so every test edit would otherwise change
          # the client's source hash and recompile all 1146 Guile modules.  The
          # client build reads nothing under daemon/test (those files are only
          # EXTRA_DIST), so drop that directory from the check's client source.
          # Filter self (the flake's already-cleaned source), not ./.: the raw
          # worktree holds untracked sockets/FIFOs that Nix cannot copy.
          clientSource = lib.cleanSourceWith {
            src = self;
            filter = path: _type:
              let rel = lib.removePrefix (toString self + "/") (toString path);
              in rel != "daemon/test" && !lib.hasPrefix "daemon/test/" rel;
          };
        in {
        hs6-build-users-vm = import ./daemon/test/build-users-vm.nix {
          inherit pkgs;
          goonixDaemon = composed.packages.${pkgs.stdenv.system}.guix-daemon-hs;
          guixClient = (mkGoonix pkgs).overrideAttrs (old: { src = clientSource; });
        };
      });

      # Everything needed to build the checkout by hand:
      #   ./bootstrap && ./configure --localstatedir=/var --sysconfdir=/etc && make
      #   ./pre-inst-env guix ...
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ (mkGoonix pkgs) ];
          # age/openssh for the build; socat and git are FIXTURE tools the
          # root-ci gate needs (root-ci-part.sh runs `socat TCP-LISTEN' for
          # builtin:download and `git daemon' for builtin:git-download).
          # Without them here the gate depends on the host PATH: on zergling2
          # socat was absent, the HTTP fixture never started, and the builder's
          # "Connection refused" read as a daemon FAIL.
          packages = [ pkgs.age pkgs.openssh pkgs.socat pkgs.git ];

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

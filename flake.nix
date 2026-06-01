{
  description = "Reprobuild development environment";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/nixos-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
    runquota-src = {
      url = "github:metacraft-labs/runquota/main";
      flake = false;
    };
    nimcrypto-src = {
      url = "github:cheatfate/nimcrypto/69eec0375dd146aede41f920c702c531bfe89c6b";
      flake = false;
    };
  };

  outputs =
    inputs@{
      flake-parts,
      git-hooks,
      nimcrypto-src,
      runquota-src,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, system, ... }:
        let
          version =
            let
              versionMatches = builtins.filter (match: match != null) (
                map (line: builtins.match ''version = "([^"]+)"'' line) (
                  pkgs.lib.splitString "\n" (builtins.readFile ./reprobuild.nimble)
                )
              );
            in
            builtins.elemAt (builtins.head versionMatches) 0;
          # libblake3 has split `out`/`dev` outputs (dev has include/blake3.h,
          # out has lib/libblake3.so). config.nims's prefix-lookup expects a
          # single tree containing both, so join them with symlinkJoin.
          blake3Prefix = pkgs.symlinkJoin {
            name = "libblake3-prefix";
            paths = [
              pkgs.libblake3.dev
              pkgs.libblake3.out
            ];
          };
          pre-commit-check = git-hooks.lib.${system}.run {
            src = ./.;
            hooks.just-lint = {
              enable = true;
              name = "just lint";
              entry = "${pkgs.writeShellScript "reprobuild-just-lint" ''
                export PATH=${
                  pkgs.lib.makeBinPath [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.gnugrep
                    pkgs.just
                    pkgs.nim2
                  ]
                }:$PATH
                export BLAKE3_PREFIX=${blake3Prefix}
                export NIMCRYPTO_SRC=${nimcrypto-src}
                export REPROBUILD_USE_SYSTEM_HASH_LIBS=1
                export RUNQUOTA_SRC=${runquota-src}
                export XXHASH_PREFIX=${pkgs.xxHash}
                exec ${pkgs.just}/bin/just lint
              ''}";
              language = "system";
              pass_filenames = false;
            };
          };
          reprobuild = pkgs.stdenv.mkDerivation {
            pname = "reprobuild";
            inherit version;
            src = ./.;

            strictDeps = true;
            dontConfigure = true;

            nativeBuildInputs = [
              pkgs.just
              pkgs.nim2
            ];

            buildInputs = [
              pkgs.libblake3
              pkgs.sqlite
              pkgs.xxHash
            ];

            BLAKE3_PREFIX = blake3Prefix;
            NIMCRYPTO_SRC = nimcrypto-src;
            REPROBUILD_USE_SYSTEM_HASH_LIBS = "1";
            RUNQUOTA_SRC = runquota-src;
            SQLITE_PREFIX = pkgs.sqlite.out;
            XXHASH_PREFIX = pkgs.xxHash;

            buildPhase = ''
              runHook preBuild
              just build
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin" "$out/lib"
              for bin in build/bin/*; do
                install -m755 "$bin" "$out/bin/$(basename "$bin")"
              done
              for lib in build/lib/*; do
                [ -e "$lib" ] || continue
                install -m755 "$lib" "$out/lib/$(basename "$lib")"
              done
              runHook postInstall
            '';

            meta = {
              description = "Reprobuild build system";
              homepage = "https://github.com/metacraft-labs/reprobuild";
              license = pkgs.lib.licenses.mit;
              mainProgram = "repro";
              platforms = [
                "x86_64-linux"
                "aarch64-linux"
                "x86_64-darwin"
                "aarch64-darwin"
              ];
            };
          };
          reproApp = {
            type = "app";
            program = "${reprobuild}/bin/repro";
          };
        in
        {
          apps.default = reproApp;
          apps.repro = reproApp;

          packages.default = reprobuild;
          packages.reprobuild = reprobuild;

          checks = {
            inherit pre-commit-check;
            package-build = reprobuild;
            repo-requirements =
              pkgs.runCommand "reprobuild-repo-requirements" { nativeBuildInputs = [ pkgs.just ]; }
                ''
                  cp -R ${./.} source
                  chmod -R u+w source
                  cd source
                  ${pkgs.bash}/bin/bash scripts/check_repo_requirements.sh
                  mkdir -p $out
                '';
          };

          devShells.default = pkgs.mkShell {
            BLAKE3_PREFIX = blake3Prefix;
            NIMCRYPTO_SRC = nimcrypto-src;
            REPROBUILD_USE_SYSTEM_HASH_LIBS = "1";
            RUNQUOTA_SRC = runquota-src;
            SQLITE_PREFIX = pkgs.sqlite.out;
            XXHASH_PREFIX = pkgs.xxHash;
            packages = [
              pkgs.just
              pkgs.nim2
              pkgs.cmake
              pkgs.ninja
              pkgs.clang
              pkgs.curl
              pkgs.libblake3
              pkgs.p7zip
              pkgs.sqlite
              pkgs.xxHash
              pkgs.zip
              pkgs.zlib
              pkgs.nixfmt-rfc-style
              pkgs.repomix
              pkgs.pre-commit
              pkgs.shellcheck
              pkgs.shfmt
              pkgs.typos
            ];
            shellHook = pre-commit-check.shellHook;
          };
        };
    };
}

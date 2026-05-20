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
  };

  outputs =
    inputs@{
      flake-parts,
      git-hooks,
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
          pre-commit-check = git-hooks.lib.${system}.run {
            src = ./.;
            hooks.just-lint = {
              enable = true;
              name = "just lint";
              entry = "just lint";
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
              pkgs.xxHash
            ];

            BLAKE3_PREFIX = pkgs.libblake3;
            RUNQUOTA_SRC = runquota-src;
            XXHASH_PREFIX = pkgs.xxHash;

            buildPhase = ''
              runHook preBuild
              just build
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin"
              for bin in build/bin/*; do
                install -m755 "$bin" "$out/bin/$(basename "$bin")"
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
            packages = [
              pkgs.just
              pkgs.nim2
              pkgs.cmake
              pkgs.ninja
              pkgs.clang
              pkgs.libblake3
              pkgs.xxHash
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

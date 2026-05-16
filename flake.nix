{
  description = "Reprobuild development environment";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/nixos-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
  };

  outputs =
    inputs@{
      flake-parts,
      git-hooks,
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
        in
        {
          packages.default = pkgs.stdenv.mkDerivation {
            pname = "reprobuild";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [
              pkgs.just
              pkgs.nim2
              pkgs.libblake3
              pkgs.xxHash
            ];
            buildPhase = "just build";
            doCheck = true;
            checkPhase = "just test";
            installPhase = ''
              mkdir -p $out/bin
              cp build/bin/* $out/bin/
            '';
          };

          checks = {
            inherit pre-commit-check;
            repo-requirements = pkgs.runCommand "reprobuild-repo-requirements" { } ''
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

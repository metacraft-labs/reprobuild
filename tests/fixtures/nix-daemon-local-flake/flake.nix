{
  description = "Lightweight local flake for reprobuild Nix daemon tests";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          let pkgs = import nixpkgs { inherit system; };
          in f system pkgs);
    in
    {
      packages = forAllSystems (system: pkgs: {
        hello-sh = pkgs.writeShellApplication {
          name = "reprobuild-nix-daemon-fixture";
          text = ''
            printf '%s\n' reprobuild-nix-daemon-fixture
          '';
        };
        default = self.packages.${system}.hello-sh;
      });
    };
}

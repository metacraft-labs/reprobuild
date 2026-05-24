import repro_project_dsl

package nix:
  provisioning:
    nixPackage "nixpkgs#nix", executablePath = "bin/nix"

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package rg:
  provisioning:
    nixPackage "nixpkgs#ripgrep", executablePath = "bin/rg",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

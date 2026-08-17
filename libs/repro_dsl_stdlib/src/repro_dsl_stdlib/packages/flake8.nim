import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package flake8:
  provisioning:
    nixPackage "nixpkgs#python3Packages.flake8", executablePath = "bin/flake8",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

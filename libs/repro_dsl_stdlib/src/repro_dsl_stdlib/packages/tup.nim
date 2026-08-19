import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package tup:
  provisioning:
    nixPackage "nixpkgs#tup", executablePath = "bin/tup",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

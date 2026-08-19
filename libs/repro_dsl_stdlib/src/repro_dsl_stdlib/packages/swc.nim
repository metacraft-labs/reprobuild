import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package swc:
  provisioning:
    nixPackage "nixpkgs#swc", executablePath = "bin/swc",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

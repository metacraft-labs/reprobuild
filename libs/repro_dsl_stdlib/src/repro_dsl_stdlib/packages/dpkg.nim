import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package dpkg:
  provisioning:
    nixPackage "nixpkgs#dpkg", executablePath = "bin/dpkg",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

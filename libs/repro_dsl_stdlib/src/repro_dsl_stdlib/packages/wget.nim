import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package wget:
  provisioning:
    nixPackage "nixpkgs#wget", executablePath = "bin/wget",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

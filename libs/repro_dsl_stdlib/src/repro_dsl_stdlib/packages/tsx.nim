import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package tsx:
  provisioning:
    nixPackage "nixpkgs#tsx", executablePath = "bin/tsx",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

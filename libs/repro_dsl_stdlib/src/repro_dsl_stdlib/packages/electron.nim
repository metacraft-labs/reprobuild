import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package electron:
  provisioning:
    nixPackage "nixpkgs#electron", executablePath = "bin/electron",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

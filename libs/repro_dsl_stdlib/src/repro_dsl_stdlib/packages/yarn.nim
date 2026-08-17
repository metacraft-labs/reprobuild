import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package yarn:
  provisioning:
    nixPackage "nixpkgs#yarn", executablePath = "bin/yarn",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package curl:
  provisioning:
    nixPackage "nixpkgs#curl", executablePath = "bin/curl",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

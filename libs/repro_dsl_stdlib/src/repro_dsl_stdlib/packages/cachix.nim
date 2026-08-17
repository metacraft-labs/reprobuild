import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package cachix:
  provisioning:
    nixPackage "nixpkgs#cachix", executablePath = "bin/cachix",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

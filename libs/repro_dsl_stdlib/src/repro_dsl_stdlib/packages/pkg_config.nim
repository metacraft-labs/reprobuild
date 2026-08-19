import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `pkg-config`:
  provisioning:
    nixPackage "nixpkgs#pkg-config", executablePath = "bin/pkg-config",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

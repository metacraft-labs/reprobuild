import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `rust-analyzer`:
  provisioning:
    nixPackage "nixpkgs#rust-analyzer", executablePath = "bin/rust-analyzer",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

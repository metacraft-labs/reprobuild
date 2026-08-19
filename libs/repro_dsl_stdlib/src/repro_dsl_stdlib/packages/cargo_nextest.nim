import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `cargo-nextest`:
  provisioning:
    nixPackage "nixpkgs#cargo-nextest", executablePath = "bin/cargo-nextest",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

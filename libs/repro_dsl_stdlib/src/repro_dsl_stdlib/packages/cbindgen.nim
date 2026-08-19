import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package cbindgen:
  provisioning:
    nixPackage "nixpkgs#rust-cbindgen", executablePath = "bin/cbindgen",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

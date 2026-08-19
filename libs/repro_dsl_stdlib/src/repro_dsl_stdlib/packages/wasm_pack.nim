import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `wasm-pack`:
  provisioning:
    nixPackage "nixpkgs#wasm-pack", executablePath = "bin/wasm-pack",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

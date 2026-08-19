import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `webpack-cli`:
  provisioning:
    nixPackage "nixpkgs#webpack-cli", executablePath = "bin/webpack",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

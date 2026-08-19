import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `tree-sitter`:
  provisioning:
    nixPackage "nixpkgs#tree-sitter", executablePath = "bin/tree-sitter",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

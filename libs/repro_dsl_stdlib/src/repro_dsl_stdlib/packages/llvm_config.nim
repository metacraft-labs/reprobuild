import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `llvm-config`:
  provisioning:
    nixPackage "nixpkgs#llvm.dev", executablePath = "bin/llvm-config",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `llvm-objdump`:
  provisioning:
    nixPackage "nixpkgs#llvm", executablePath = "bin/llvm-objdump",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

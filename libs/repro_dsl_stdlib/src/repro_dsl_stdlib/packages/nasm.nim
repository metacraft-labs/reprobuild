## Bootstrap provisioning adapter for the NASM assembler.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `nasm`:
  provisioning:
    nixPackage "nixpkgs#nasm", executablePath = "bin/nasm",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

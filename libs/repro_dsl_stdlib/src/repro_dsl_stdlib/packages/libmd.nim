## Bootstrap provisioning adapter for libmd.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libmd`:
  provisioning:
    nixPackage "nixpkgs#libmd", executablePath = "lib/libmd.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

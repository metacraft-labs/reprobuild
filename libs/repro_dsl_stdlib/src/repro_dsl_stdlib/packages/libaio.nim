## Bootstrap provisioning adapter for libaio.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libaio`:
  provisioning:
    nixPackage "nixpkgs#libaio", executablePath = "lib/libaio.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

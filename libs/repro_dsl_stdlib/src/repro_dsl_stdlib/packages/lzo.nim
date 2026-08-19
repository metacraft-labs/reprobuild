## Bootstrap provisioning adapter for lzo.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `lzo`:
  provisioning:
    nixPackage "nixpkgs#lzo", executablePath = "lib/liblzo2.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

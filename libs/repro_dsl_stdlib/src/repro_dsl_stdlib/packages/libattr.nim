## Stdlib provisioning adapter for the extended-attributes library.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libattr`:
  provisioning:
    nixPackage "nixpkgs#attr", executablePath = "lib/libattr.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

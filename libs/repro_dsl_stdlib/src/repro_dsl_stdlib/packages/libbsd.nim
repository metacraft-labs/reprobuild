## Bootstrap provisioning adapter for libbsd.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libbsd`:
  provisioning:
    nixPackage "nixpkgs#libbsd", executablePath = "lib/libbsd.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

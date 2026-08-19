## Bootstrap provisioning adapter for gusb.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `gusb`:
  provisioning:
    nixPackage "nixpkgs#gusb", executablePath = "lib/libgusb.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

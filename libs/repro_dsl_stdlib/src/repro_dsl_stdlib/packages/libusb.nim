## Bootstrap provisioning adapter for libusb.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libusb`:
  provisioning:
    nixPackage "nixpkgs#libusb1", executablePath = "lib/libusb-1.0.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

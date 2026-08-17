## Bootstrap provisioning adapter for pthread-stubs pkg-config data.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libpthread-stubs`:
  provisioning:
    nixPackage "nixpkgs#xorg.libpthreadstubs",
      executablePath = "lib/pkgconfig/pthread-stubs.pc",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

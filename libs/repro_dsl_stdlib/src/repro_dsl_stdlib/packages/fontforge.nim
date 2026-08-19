## Bootstrap tool provisioning for generating fonts from SFD sources.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package fontforge:
  provisioning:
    nixPackage "nixpkgs#fontforge", executablePath = "bin/fontforge",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

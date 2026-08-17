## Bootstrap provisioning adapter for the xsltproc code generator.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libxslt`:
  provisioning:
    nixPackage "nixpkgs#libxslt", executablePath = "bin/xsltproc",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

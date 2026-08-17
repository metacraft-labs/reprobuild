import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `xvfb-run`:
  provisioning:
    nixPackage "nixpkgs#xvfb-run", executablePath = "bin/xvfb-run",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

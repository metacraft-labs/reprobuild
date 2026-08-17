import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package pkgconf:
  provisioning:
    nixPackage "nixpkgs#pkgconf", executablePath = "bin/pkgconf",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

  executable pkgconf:
    discard

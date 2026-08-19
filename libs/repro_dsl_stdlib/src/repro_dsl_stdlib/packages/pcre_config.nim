import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `pcre-config`:
  provisioning:
    nixPackage "nixpkgs#pcre.dev", executablePath = "bin/pcre-config",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash,
      packageId = "pcre"

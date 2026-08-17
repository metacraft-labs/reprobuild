import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package shellcheck:
  provisioning:
    nixPackage "nixpkgs#shellcheck", executablePath = "bin/shellcheck",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

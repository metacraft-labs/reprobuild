import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package vim:
  provisioning:
    nixPackage "nixpkgs#vim", executablePath = "bin/vim",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package ctags:
  provisioning:
    nixPackage "nixpkgs#universal-ctags", executablePath = "bin/ctags",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

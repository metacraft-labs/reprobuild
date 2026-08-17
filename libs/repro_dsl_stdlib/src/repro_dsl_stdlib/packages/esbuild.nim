import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package esbuild:
  provisioning:
    nixPackage "nixpkgs#esbuild", executablePath = "bin/esbuild",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

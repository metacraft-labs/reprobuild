import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

# Provides the TypeScript compiler. The executable on disk is named ``tsc``,
# not ``typescript``; the package name here matches the catalog entry, not
# the on-disk binary.
package typescript:
  provisioning:
    nixPackage "nixpkgs#typescript", executablePath = "bin/tsc",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

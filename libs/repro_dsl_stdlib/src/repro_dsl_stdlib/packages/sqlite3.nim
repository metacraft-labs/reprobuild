import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package sqlite3:
  provisioning:
    nixPackage "nixpkgs#sqlite", executablePath = "bin/sqlite3",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

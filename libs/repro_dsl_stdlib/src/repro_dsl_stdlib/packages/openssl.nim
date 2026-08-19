import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package openssl:
  provisioning:
    nixPackage "nixpkgs#openssl", executablePath = "bin/openssl",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

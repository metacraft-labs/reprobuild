import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package bpftrace:
  provisioning:
    nixPackage "nixpkgs#bpftrace", executablePath = "bin/bpftrace",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

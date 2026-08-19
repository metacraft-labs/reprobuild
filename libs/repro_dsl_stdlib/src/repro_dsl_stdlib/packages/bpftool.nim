import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package bpftool:
  provisioning:
    nixPackage "nixpkgs#bpftools", executablePath = "bin/bpftool",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

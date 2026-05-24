import repro_project_dsl

package bpftrace:
  provisioning:
    nixPackage "nixpkgs#bpftrace", executablePath = "bin/bpftrace"

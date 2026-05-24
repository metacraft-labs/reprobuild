import repro_project_dsl

package bpftool:
  provisioning:
    nixPackage "nixpkgs#bpftools", executablePath = "bin/bpftool"

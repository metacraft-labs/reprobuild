import repro_project_dsl

package `rust-analyzer`:
  provisioning:
    nixPackage "nixpkgs#rust-analyzer", executablePath = "bin/rust-analyzer"

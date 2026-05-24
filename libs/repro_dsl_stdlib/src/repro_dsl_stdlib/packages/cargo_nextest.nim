import repro_project_dsl

package `cargo-nextest`:
  provisioning:
    nixPackage "nixpkgs#cargo-nextest", executablePath = "bin/cargo-nextest"

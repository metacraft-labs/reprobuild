import repro_project_dsl

package rustup:
  provisioning:
    nixPackage "nixpkgs#rustup", executablePath = "bin/rustup"

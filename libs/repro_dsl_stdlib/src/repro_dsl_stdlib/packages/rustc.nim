import repro_project_dsl

package rustc:
  provisioning:
    nixPackage "nixpkgs#rustc", executablePath = "bin/rustc"

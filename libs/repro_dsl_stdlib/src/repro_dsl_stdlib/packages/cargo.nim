import repro_project_dsl

package cargo:
  provisioning:
    nixPackage "nixpkgs#cargo", executablePath = "bin/cargo"

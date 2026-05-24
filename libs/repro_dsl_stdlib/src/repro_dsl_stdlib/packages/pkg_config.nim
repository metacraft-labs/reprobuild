import repro_project_dsl

package `pkg-config`:
  provisioning:
    nixPackage "nixpkgs#pkg-config", executablePath = "bin/pkg-config"

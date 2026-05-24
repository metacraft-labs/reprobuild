import repro_project_dsl

package just:
  provisioning:
    nixPackage "nixpkgs#just", executablePath = "bin/just"

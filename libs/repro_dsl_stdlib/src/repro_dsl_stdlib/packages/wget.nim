import repro_project_dsl

package wget:
  provisioning:
    nixPackage "nixpkgs#wget", executablePath = "bin/wget"

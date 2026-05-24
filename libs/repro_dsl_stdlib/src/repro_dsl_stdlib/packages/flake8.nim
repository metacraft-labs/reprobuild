import repro_project_dsl

package flake8:
  provisioning:
    nixPackage "nixpkgs#python3Packages.flake8", executablePath = "bin/flake8"

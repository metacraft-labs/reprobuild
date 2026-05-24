import repro_project_dsl

package dpkg:
  provisioning:
    nixPackage "nixpkgs#dpkg", executablePath = "bin/dpkg"

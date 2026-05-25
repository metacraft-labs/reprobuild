import repro_project_dsl

package `webpack-cli`:
  provisioning:
    nixPackage "nixpkgs#webpack-cli", executablePath = "bin/webpack"

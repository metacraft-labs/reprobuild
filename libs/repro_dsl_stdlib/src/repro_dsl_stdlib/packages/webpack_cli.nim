import repro_project_dsl

package `webpack-cli`:
  provisioning:
    nixPackage "nixpkgs#nodePackages.webpack-cli", executablePath = "bin/webpack-cli"

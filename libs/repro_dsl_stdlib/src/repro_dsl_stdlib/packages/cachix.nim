import repro_project_dsl

package cachix:
  provisioning:
    nixPackage "nixpkgs#cachix", executablePath = "bin/cachix"

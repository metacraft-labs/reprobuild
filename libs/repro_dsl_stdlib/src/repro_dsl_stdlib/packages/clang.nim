import repro_project_dsl

package clang:
  provisioning:
    nixPackage "nixpkgs#clang", executablePath = "bin/clang"

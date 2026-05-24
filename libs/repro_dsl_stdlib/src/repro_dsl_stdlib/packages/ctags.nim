import repro_project_dsl

package ctags:
  provisioning:
    nixPackage "nixpkgs#universal-ctags", executablePath = "bin/ctags"

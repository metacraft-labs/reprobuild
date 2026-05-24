import repro_project_dsl

package git:
  provisioning:
    nixPackage "nixpkgs#git", executablePath = "bin/git"

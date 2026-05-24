import repro_project_dsl

package npx:
  provisioning:
    nixPackage "nixpkgs#nodejs", executablePath = "bin/npx"

import repro_project_dsl

package electron:
  provisioning:
    nixPackage "nixpkgs#electron", executablePath = "bin/electron"

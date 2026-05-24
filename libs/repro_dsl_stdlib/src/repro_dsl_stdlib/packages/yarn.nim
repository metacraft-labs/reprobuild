import repro_project_dsl

package yarn:
  provisioning:
    nixPackage "nixpkgs#yarn", executablePath = "bin/yarn"

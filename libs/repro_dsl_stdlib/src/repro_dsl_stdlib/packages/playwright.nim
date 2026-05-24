import repro_project_dsl

package playwright:
  provisioning:
    nixPackage "nixpkgs#playwright", executablePath = "bin/playwright"

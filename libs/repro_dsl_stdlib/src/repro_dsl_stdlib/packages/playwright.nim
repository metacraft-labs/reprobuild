import repro_project_dsl

package playwright:
  provisioning:
    nixPackage "nixpkgs#playwright-test", executablePath = "bin/playwright",
      packageId = "playwright"

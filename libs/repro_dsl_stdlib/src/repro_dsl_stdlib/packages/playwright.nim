import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package playwright:
  provisioning:
    nixPackage "nixpkgs#playwright-test", executablePath = "bin/playwright",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash,
      packageId = "playwright"

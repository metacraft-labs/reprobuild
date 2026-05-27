import repro_project_dsl

# Provides the TypeScript compiler. The executable on disk is named ``tsc``,
# not ``typescript``; the package name here matches the catalog entry, not
# the on-disk binary.
package typescript:
  provisioning:
    nixPackage "nixpkgs#typescript", executablePath = "bin/tsc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

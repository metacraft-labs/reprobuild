import repro_project_dsl

package rustc:
  provisioning:
    nixPackage "nixpkgs#rustc", executablePath = "bin/rustc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

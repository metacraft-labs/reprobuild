import repro_project_dsl

package `create-dmg`:
  provisioning:
    nixPackage "nixpkgs#create-dmg", executablePath = "bin/create-dmg",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8=",
      packageId = "create-dmg@1.2.2"

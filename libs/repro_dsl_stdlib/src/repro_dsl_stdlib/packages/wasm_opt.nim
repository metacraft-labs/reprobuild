import repro_project_dsl

package `wasm-opt`:
  provisioning:
    nixPackage "nixpkgs#binaryen", executablePath = "bin/wasm-opt",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

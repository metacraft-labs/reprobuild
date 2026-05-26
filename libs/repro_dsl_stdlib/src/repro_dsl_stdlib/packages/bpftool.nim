import repro_project_dsl

package bpftool:
  provisioning:
    nixPackage "nixpkgs#bpftools", executablePath = "bin/bpftool",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

import repro_project_dsl

package nix:
  provisioning:
    # The default `nix`/`stable` attributes at this pinned nixpkgs revision
    # build locally on aarch64-darwin. 2.28.5 has upstream cache.nixos.org
    # substitutes and is sufficient for Reprobuild's own Nix invocations.
    nixPackage "nixpkgs#nixVersions.nix_2_28", executablePath = "bin/nix",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8=",
      packageId = "nix@2.28.5"

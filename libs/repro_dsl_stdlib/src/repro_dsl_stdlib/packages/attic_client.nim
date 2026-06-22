import repro_project_dsl

# Attic is the Nix binary-cache client CodeTracer migrated to from Cachix
# (see ``cachix.nim`` for the predecessor). The nixpkgs ``attic-client``
# package ships the ``attic`` binary (``meta.mainProgram = "attic"``), so
# ``executablePath`` points at ``bin/attic`` even though the ``uses:``
# selector is ``attic-client``.
package `attic-client`:
  provisioning:
    nixPackage "nixpkgs#attic-client", executablePath = "bin/attic",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

# Attic is the Nix binary-cache client CodeTracer migrated to from Cachix
# (see ``cachix.nim`` for the predecessor). The nixpkgs ``attic-client``
# package ships the ``attic`` binary (``meta.mainProgram = "attic"``), so
# ``executablePath`` points at ``bin/attic`` even though the ``uses:``
# selector is ``attic-client``.
package `attic-client`:
  provisioning:
    nixPackage "nixpkgs#attic-client", executablePath = "bin/attic",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

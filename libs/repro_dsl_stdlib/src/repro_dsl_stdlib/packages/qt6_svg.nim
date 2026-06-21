## DSL-port M9.R.15k.1 — stdlib provisioning stub for ``qt6-svg``.
##
## Lifted from the M9.R.10a exec-name audit pass shape: this package
## surfaces as a ``nativeBuildDeps`` / ``buildDeps`` entry on KF6
## source recipes (kiconthemes, ksvg, kxmlgui) under
## ``recipes/packages/source/``. The stub registers the canonical name +
## a Nix provisioning channel so the resolver can find a usable adapter
## under ``--tool-provisioning=from-source`` / ``--tool-provisioning=nix``.

import repro_project_dsl

package `qt6-svg`:
  provisioning:
    nixPackage "nixpkgs#qt6.qtsvg", executablePath = "lib/libQt6Svg.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

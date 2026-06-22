## DSL-port M9.R.15q.4.5 — stdlib provisioning stub for ``kdecoration2``.
##
## ``kdecoration2`` (KDecoration2 in upstream) is the abstract window-
## decoration framework kwin uses for server-side decorations.
## ``find_package(KDecoration2 ...)`` is a REQUIRED dep in kwin's
## CMakeLists.txt; the kwin compositor links against ``libKDecoration2.so``
## to register its built-in decoration plugins (Breeze, Plastik) +
## the third-party decoration ABI surface.
##
## ## Provisioning channel — nixpkgs#kdePackages.kdecoration

import repro_project_dsl

package `kdecoration2`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kdecoration", executablePath = "lib/libkdecorations3.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

## DSL-port M9.R.15q.4.5 — stdlib provisioning stub for
## ``libqaccessibilityclient``.
##
## ``libqaccessibilityclient`` (QAccessibilityClient6 in upstream)
## is the KDE client-side accessibility library kwin uses to expose
## the compositor's accessibility surface to AT-SPI. Optional dep in
## kwin's CMakeLists.txt.
##
## ## Provisioning channel — nixpkgs#libqaccessibilityclient

import repro_project_dsl

package `libqaccessibilityclient`:
  provisioning:
    nixPackage "nixpkgs#libqaccessibilityclient", executablePath = "lib/cmake/QAccessibilityClient6/QAccessibilityClient6Config.cmake",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

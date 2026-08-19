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
import repro_dsl_stdlib/nixpkgs_pin

package `libqaccessibilityclient`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.libqaccessibilityclient", executablePath = "lib/libqaccessibilityclient-qt6.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

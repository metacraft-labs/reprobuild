## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``breeze``.
##
## ``breeze`` (Breeze in upstream) is the Plasma default visual style:
## Qt-style plugin + window-decoration plugin + icon + sound themes.
## REQUIRED at plasma-workspace configure time for the
## ``find_package(Breeze REQUIRED)`` probe and at run-time for the
## default Plasma session look-and-feel.
##
## ## Provisioning channel — nixpkgs#kdePackages.breeze

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `breeze`:
  provisioning:
    ## breeze ships as Qt plugins (no top-level .so); pin the Qt style
    ## plugin as the existence-check anchor.
    nixPackage "nixpkgs#kdePackages.breeze", executablePath = "lib/qt-6/plugins/styles/breeze6.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

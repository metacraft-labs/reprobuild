## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``layer-shell-qt``.
##
## ``layer-shell-qt`` (LayerShellQt in upstream) is the Qt-binding for
## the wlr-layer-shell Wayland protocol (the surface-layering protocol
## that gives panels / docks / lock-screens their reserved screen
## regions).  REQUIRED dep on plasma-workspace's
## ``find_package(LayerShellQt REQUIRED)`` probe; the Plasma shell uses
## layer-shell to anchor its task bar to the bottom edge.
##
## ## Provisioning channel — nixpkgs#kdePackages.layer-shell-qt

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `layer-shell-qt`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.layer-shell-qt", executablePath = "lib/libLayerShellQtInterface.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

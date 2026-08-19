## DSL-port M9.R.15q.4.5 — stdlib provisioning stub for ``kwayland``.
##
## ``kwayland`` (KWayland in upstream, the Plasma-stack package) is
## the KDE Frameworks Wayland client/server library kwin's wayland
## backend uses to expose KDE-specific wayland surfaces. REQUIRED
## by kwin's CMakeLists.txt.
##
## ## Provisioning channel — nixpkgs#kdePackages.kwayland

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `kwayland`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kwayland", executablePath = "lib/libKWaylandClient.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

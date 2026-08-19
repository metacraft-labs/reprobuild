## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``kscreen``.
##
## ``kscreen`` (libkscreen in upstream) is the multi-monitor
## configuration library backing the Plasma display-arrangement KCM.
## REQUIRED dep on plasma-workspace's
## ``find_package(KScreen REQUIRED)`` probe; the Plasma session
## leader applies kscreen profiles at start-up to restore the user's
## per-output rotation + scale + position.
##
## ## Provisioning channel — nixpkgs#kdePackages.libkscreen

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `kscreen`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.libkscreen", executablePath = "lib/libKF6Screen.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

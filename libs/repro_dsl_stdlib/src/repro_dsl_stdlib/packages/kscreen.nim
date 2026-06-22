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

package `kscreen`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.libkscreen", executablePath = "lib/libKF6Screen.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

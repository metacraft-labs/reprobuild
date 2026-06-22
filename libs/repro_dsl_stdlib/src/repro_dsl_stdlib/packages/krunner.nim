## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``krunner``.
##
## ``krunner`` (KRunner in upstream KF6) is the Plasma quick-launcher /
## command framework.  REQUIRED dep on plasma-workspace's
## ``find_package(KF6Runner REQUIRED)`` probe (krunner is the engine
## that backs the Plasma "search and launch" panel widget).
##
## ## Provisioning channel — nixpkgs#kdePackages.krunner

import repro_project_dsl

package `krunner`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.krunner", executablePath = "lib/libKF6Runner.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

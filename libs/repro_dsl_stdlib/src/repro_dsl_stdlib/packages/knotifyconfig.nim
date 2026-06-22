## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``knotifyconfig``.
##
## ``knotifyconfig`` (KNotifyConfig in upstream KF6) is the UI helper
## for per-application notification configuration (the .notifyrc
## editor).  REQUIRED dep on plasma-workspace's
## ``find_package(KF6NotifyConfig REQUIRED)`` probe.
##
## ## Provisioning channel — nixpkgs#kdePackages.knotifyconfig

import repro_project_dsl

package `knotifyconfig`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.knotifyconfig", executablePath = "lib/libKF6NotifyConfig.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

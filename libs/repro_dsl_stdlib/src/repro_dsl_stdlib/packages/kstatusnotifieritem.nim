## DSL-port M9.R.15q.9.8 — stdlib provisioning stub for ``kstatusnotifieritem``.
##
## ``kstatusnotifieritem`` (KStatusNotifierItem in upstream KF6) is the
## system-tray protocol library Plasma uses for the freedesktop
## StatusNotifierItem D-Bus protocol.  REQUIRED dep on plasma-
## workspace's ``find_package(KF6 ... COMPONENTS StatusNotifierItem
## REQUIRED)`` probe.
##
## ## Provisioning channel — nixpkgs#kdePackages.kstatusnotifieritem

import repro_project_dsl

package `kstatusnotifieritem`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kstatusnotifieritem", executablePath = "lib/libKF6StatusNotifierItem.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

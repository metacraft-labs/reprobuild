## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``ktextwidgets``.
##
## ``ktextwidgets`` (KTextWidgets in upstream KF6) extends Qt's rich-
## text-edit widget with KDE-style spell-check / find-replace / format
## bar.  REQUIRED dep on plasma-workspace's
## ``find_package(KF6TextWidgets REQUIRED)`` probe.
##
## ## Provisioning channel — nixpkgs#kdePackages.ktextwidgets

import repro_project_dsl

package `ktextwidgets`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.ktextwidgets", executablePath = "lib/libKF6TextWidgets.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

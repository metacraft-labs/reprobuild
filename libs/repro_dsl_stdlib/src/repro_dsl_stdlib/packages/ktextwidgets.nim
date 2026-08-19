## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``ktextwidgets``.
##
## ``ktextwidgets`` (KTextWidgets in upstream KF6) extends Qt's rich-
## text-edit widget with KDE-style spell-check / find-replace / format
## bar.  REQUIRED dep on plasma-workspace's
## ``find_package(KF6TextWidgets REQUIRED)`` probe.
##
## ## Provisioning channel — nixpkgs#kdePackages.ktextwidgets

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `ktextwidgets`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.ktextwidgets", executablePath = "lib/libKF6TextWidgets.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

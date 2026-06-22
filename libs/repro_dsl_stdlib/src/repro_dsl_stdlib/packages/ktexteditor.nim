## DSL-port M9.R.15q.9.8 — stdlib provisioning stub for ``ktexteditor``.
##
## ``ktexteditor`` (KTextEditor in upstream KF6) is the powerful text-
## editing widget framework Kate / KWrite are built on.  REQUIRED dep
## on plasma-workspace's
## ``find_package(KF6 ... COMPONENTS TextEditor REQUIRED)`` probe.
##
## ## Provisioning channel — nixpkgs#kdePackages.ktexteditor

import repro_project_dsl

package `ktexteditor`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.ktexteditor", executablePath = "lib/libKF6TextEditor.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

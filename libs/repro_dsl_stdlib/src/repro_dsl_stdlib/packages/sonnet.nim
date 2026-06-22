## DSL-port M9.R.15q.9.9 — stdlib provisioning stub for ``sonnet``.
##
## ``sonnet`` (KF6Sonnet in upstream) is the KF6 spell-checking
## library. Surfaces as a TRANSITIVE find_package probe via
## ktextwidgets's CMake config (``KF6TextWidgets`` depends on
## ``KF6Sonnet`` at configure time).
##
## ## Provisioning channel — nixpkgs#kdePackages.sonnet

import repro_project_dsl

package `sonnet`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.sonnet", executablePath = "lib/libKF6SonnetCore.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

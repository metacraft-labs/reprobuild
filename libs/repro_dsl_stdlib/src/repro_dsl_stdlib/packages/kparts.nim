## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``kparts``.
##
## ``kparts`` (KParts in upstream KF6) is the document-component
## framework that allows embedding application views inside a host
## window.  REQUIRED dep on plasma-workspace's CMakeLists.txt
## ``find_package(KF6Parts REQUIRED)`` probe.
##
## ## Provisioning channel — nixpkgs#kdePackages.kparts

import repro_project_dsl

package `kparts`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kparts", executablePath = "lib/libKF6Parts.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

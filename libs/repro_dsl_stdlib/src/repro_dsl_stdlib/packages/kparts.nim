## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``kparts``.
##
## ``kparts`` (KParts in upstream KF6) is the document-component
## framework that allows embedding application views inside a host
## window.  REQUIRED dep on plasma-workspace's CMakeLists.txt
## ``find_package(KF6Parts REQUIRED)`` probe.
##
## ## Provisioning channel — nixpkgs#kdePackages.kparts

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `kparts`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kparts", executablePath = "lib/libKF6Parts.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

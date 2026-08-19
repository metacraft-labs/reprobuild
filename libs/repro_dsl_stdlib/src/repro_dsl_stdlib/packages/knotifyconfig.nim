## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``knotifyconfig``.
##
## ``knotifyconfig`` (KNotifyConfig in upstream KF6) is the UI helper
## for per-application notification configuration (the .notifyrc
## editor).  REQUIRED dep on plasma-workspace's
## ``find_package(KF6NotifyConfig REQUIRED)`` probe.
##
## ## Provisioning channel — nixpkgs#kdePackages.knotifyconfig

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `knotifyconfig`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.knotifyconfig", executablePath = "lib/libKF6NotifyConfig.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

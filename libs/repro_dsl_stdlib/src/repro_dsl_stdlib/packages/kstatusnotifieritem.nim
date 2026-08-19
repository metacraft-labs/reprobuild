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
import repro_dsl_stdlib/nixpkgs_pin

package `kstatusnotifieritem`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kstatusnotifieritem", executablePath = "lib/libKF6StatusNotifierItem.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

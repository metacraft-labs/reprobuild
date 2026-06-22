## DSL-port M9.R.15q.9.8 — stdlib provisioning stub for ``kunitconversion``.
##
## ``kunitconversion`` (KUnitConversion in upstream KF6) is the unit-
## conversion library KF6 modules use to translate between units of
## measurement.  REQUIRED dep on plasma-workspace's
## ``find_package(KF6 ... COMPONENTS UnitConversion REQUIRED)`` probe.
##
## ## Provisioning channel — nixpkgs#kdePackages.kunitconversion

import repro_project_dsl

package `kunitconversion`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kunitconversion", executablePath = "lib/libKF6UnitConversion.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

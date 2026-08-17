## DSL-port M9.R.15q.9.8 — stdlib provisioning stub for ``kunitconversion``.
##
## ``kunitconversion`` (KUnitConversion in upstream KF6) is the unit-
## conversion library KF6 modules use to translate between units of
## measurement.  REQUIRED dep on plasma-workspace's
## ``find_package(KF6 ... COMPONENTS UnitConversion REQUIRED)`` probe.
##
## ## Provisioning channel — nixpkgs#kdePackages.kunitconversion

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `kunitconversion`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kunitconversion", executablePath = "lib/libKF6UnitConversion.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``plasma-activities-stats``.
##
## ``plasma-activities-stats`` (PlasmaActivitiesStats in upstream) is
## the read-side library for the Plasma KActivities usage database
## (recently-used files, frequently-used apps).  REQUIRED dep on
## plasma-workspace's ``find_package(PlasmaActivitiesStats REQUIRED)``
## probe; the Plasma activity-switcher widget queries this for the
## per-activity recent-document list.
##
## ## Provisioning channel — nixpkgs#kdePackages.plasma-activities-stats

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `plasma-activities-stats`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.plasma-activities-stats", executablePath = "lib/libPlasmaActivitiesStats.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

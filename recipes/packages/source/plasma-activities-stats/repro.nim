## Source-from-tarball plasma-activities-stats recipe — M9.R.15q.10.8
## Plasma cascade. The plasma-activities usage-stats backend
## (``libPlasmaActivitiesStats.so``).
##
## sha256 = cddba25924651e0f5de74a6faabc8990301857bb31f4ee4ac1f69d7a0c48532c

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package plasmaActivitiesStatsSource:
  versions:
    "6.2.5":
      sourceRevision = "v6.2.5"
      sourceUrl = "https://download.kde.org/stable/plasma/6.2.5/plasma-activities-stats-6.2.5.tar.xz"
      sourceRepository = "https://invent.kde.org/plasma/plasma-activities-stats"

  fetch:
    url: "https://download.kde.org/stable/plasma/6.2.5/plasma-activities-stats-6.2.5.tar.xz"
    sha256: "cddba25924651e0f5de74a6faabc8990301857bb31f4ee4ac1f69d7a0c48532c"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "kconfig >=6.0"
    "kcoreaddons >=6.0"
    "plasma-activities >=6.2"
    "boost >=1.49"

  config:
    discard

  library libPlasmaActivitiesStats:
    discard

  build:
    setCurrentOwningPackageOverride("plasmaActivitiesStatsSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libPlasmaActivitiesStats")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard

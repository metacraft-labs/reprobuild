## Source-from-tarball kdecoration2 recipe — M9.R.15q.11.12 Plasma
## cascade module. KDecoration is the abstract window-decoration
## framework kwin uses for server-side decorations. breeze's Qt6
## decoration plugin links against libkdecorations3.so.
##
## The upstream tarball at Plasma 6.2.5 is named ``kdecoration-6.2.5``
## (no version-2 suffix); the recipe directory is ``kdecoration2`` to
## match the canonical dep declaration spelling consumers use
## (kdecoration2 was the project's KF5-era name; the KF6/Plasma 6
## artifact is libkdecorations3.so but the package name kept the
## kdecoration2 alias).
##
## sha256 = 726c58cd4b34fc49546578727a447c76242938add577292cd334bd60bf9d8f26

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kdecoration2Source:
  versions:
    "6.2.5":
      sourceRevision = "v6.2.5"
      sourceUrl = "https://download.kde.org/stable/plasma/6.2.5/kdecoration-6.2.5.tar.xz"
      sourceRepository = "https://invent.kde.org/plasma/kdecoration"

  fetch:
    url: "https://download.kde.org/stable/plasma/6.2.5/kdecoration-6.2.5.tar.xz"
    sha256: "726c58cd4b34fc49546578727a447c76242938add577292cd334bd60bf9d8f26"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "kcoreaddons >=6.0"
    "ki18n >=6.0"

  config:
    discard

  library libkdecorations3:
    discard

  build:
    setCurrentOwningPackageOverride("kdecoration2Source")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libkdecorations3")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard

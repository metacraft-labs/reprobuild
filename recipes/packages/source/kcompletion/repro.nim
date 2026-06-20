## Source-from-tarball kcompletion recipe — M9.R.15h.4 KF6 cascade
## module. kcompletion is Tier-3 KDE Frameworks: text completion
## widgets (KComboBox + KLineEdit + KHistoryComboBox) used by
## KIO file dialogs + Plasma launchers + KCompletionBox.
##
## sha256 = b56e925bbe881c89fce9c80441e1565ad1adfcb16f1cac5bb08a281fb9334bc9
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  kcompletion-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kcompletionSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kcompletion-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kcompletion"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kcompletion-6.10.0.tar.xz"
    sha256: "b56e925bbe881c89fce9c80441e1565ad1adfcb16f1cac5bb08a281fb9334bc9"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "kconfig >=6.0"
    "kwidgetsaddons >=6.0"

  config:
    discard

  library libKF6Completion:
    discard

  build:
    setCurrentOwningPackageOverride("kcompletionSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6Completion")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard

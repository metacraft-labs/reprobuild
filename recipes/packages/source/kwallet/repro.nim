## Source-from-tarball kwallet recipe — M9.R.15q.10.3 KF6 cascade
## module. kwallet is Tier-3 KDE Frameworks: the secret store
## (``libKF6Wallet.so``).
##
## sha256 = e1993911a15b4318d64abce0acdc1b5fc5a6116dc7595eff86dde03b35e6bd50

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kwalletSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kwallet-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kwallet"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kwallet-6.10.0.tar.xz"
    sha256: "e1993911a15b4318d64abce0acdc1b5fc5a6116dc7595eff86dde03b35e6bd50"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "ki18n >=6.0"
    "kconfig >=6.0"
    "kcoreaddons >=6.0"
    "kconfigwidgets >=6.0"
    "kdbusaddons >=6.0"
    "knotifications >=6.0"
    "kcrash >=6.0"
    "kwidgetsaddons >=6.0"
    "kwindowsystem >=6.0"
    "kiconthemes >=6.0"
    ## M9.R.15q.10.5 — X11 transitive via kwindowsystem.
    "xorgproto"
    "libx11"
    "libxcb"
    "libxau"
    "libxdmcp"
    "xcb-util-keysyms"
    "xcb-util-wm"
    "libxext"
    "libxfixes"
    "libxrender"

  config:
    discard

  library libKF6Wallet:
    discard

  build:
    setCurrentOwningPackageOverride("kwalletSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "CMAKE_BUILD_TYPE=Release",
        # M9.R.15q.10.7 — disable the kwalletd daemon build. It pulls in
        # Qca-qt6 (cryptographic abstraction) which we don't ship from-
        # source yet and have no nix-stub for. plasma-workspace's
        # umbrella probe only needs ``libKF6Wallet.so`` + the cmake
        # config, not the daemon binary.
        "BUILD_KWALLETD=OFF",
        "BUILD_KWALLET_QUERY=OFF",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6Wallet")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard

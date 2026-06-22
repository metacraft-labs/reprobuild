## Source-from-tarball breeze recipe — M9.R.15q.11.8 Plasma cascade
## module. Breeze is the Plasma default visual style + theme:
## QStyle-derived widget style (libbreezecommon6) + KDecoration2-based
## window decoration (libbreezedecoration6) + Kirigami-style platform
## binding. plasma-workspace + plasma-desktop's KCMs link against the
## libbreezecommon6.so.
##
## sha256 = 1d3bd4481bb7cd274a13ac5d5852be51ff2975e620872dfc22fbd531bad04e25

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package breezeSource:
  versions:
    "6.2.5":
      sourceRevision = "v6.2.5"
      sourceUrl = "https://download.kde.org/stable/plasma/6.2.5/breeze-6.2.5.tar.xz"
      sourceRepository = "https://invent.kde.org/plasma/breeze"

  fetch:
    url: "https://download.kde.org/stable/plasma/6.2.5/breeze-6.2.5.tar.xz"
    sha256: "1d3bd4481bb7cd274a13ac5d5852be51ff2975e620872dfc22fbd531bad04e25"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "qt6-declarative >=6.6"
    ## KF6 modules pulled in by breeze's find_package(KF6 ... REQUIRED
    ## COMPONENTS CoreAddons ColorScheme Config GuiAddons I18n
    ## IconThemes WindowSystem).
    "kcoreaddons >=6.0"
    "kcolorscheme >=6.0"
    "kconfig >=6.0"
    "kguiaddons >=6.0"
    "ki18n >=6.0"
    "kiconthemes >=6.0"
    "kwindowsystem >=6.0"
    ## KDecoration2 for the window-decoration plugin.
    "kdecoration2 >=6.0"
    ## M9.R.15q.11.11 — kirigami ships KF6KirigamiPlatform that
    ## breeze's CMakeLists declares find_package(KF6KirigamiPlatform
    ## ${KF6_MIN_VERSION} REQUIRED) when Qt6Quick is found.
    "kirigami >=6.0"
    ## M9.R.15q.11.14 — kcmutils ships the kcmutils_generate_desktop_file
    ## CMake helper macro the breeze kdecoration/config subdir calls.
    ## Without KF6KCMUtils config visible the helper macro is undefined.
    "kcmutils >=6.0"
    ## X11 transitives (kwindowsystem's X11 backend probe).
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

  ## breeze 6.2.5 ships only Qt plugins (under
  ## ``lib/plugins/styles/`` + ``lib/plugins/org.kde.kdecoration2/``)
  ## NOT a top-level ``libbreezecommon6.so``. The plugin set is the
  ## primary artifact plasma-workspace consumes via QStyle's plugin
  ## probe.
  ##
  ## v1 records the install-tree as a whole rather than a single
  ## library artifact (cmake_package's library stage-copy probes
  ## $libdir for the literal SONAME — there isn't one).
  build:
    setCurrentOwningPackageOverride("breezeSource")
    try:
      # v1 ships pure Qt6 — disable the Qt5 build branch so the
      # find_package(Qt5 5.15.2 REQUIRED ...) probe doesn't run
      # (we don't ship Qt5 from-source).
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
        "BUILD_QT5=OFF",
        "BUILD_QT6=ON",
      ]
      # M9.R.15q.11.15 — no .library() call: breeze installs only Qt
      # plugins, not a top-level library. The cmake_package configure
      # + build + install + install-mirror chain runs and publishes
      # the install-tree under .repro/output/install/ for downstream
      # plasma-workspace consumption.
      discard cmake_package(srcDir = "./src", cacheVars = opts)
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard

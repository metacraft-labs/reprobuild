## M9.R.18.13 -- reprobuild recipe wrapping the ReproOS Installer
## CMakeLists.txt.
##
## Per ReproOS-Installer-PRD.md Sec 7.1 the installer is a Qt6/QML app
## built via cmake against Qt6Core / Qt6Gui / Qt6Qml / Qt6Quick /
## Qt6QuickControls2. The CMakeLists.txt in this directory is
## standalone-buildable (`cmake -S . -B build && cmake --build build`);
## this recipe wraps the build for the reprobuild engine so the engine
## fingerprints the inputs, action-caches the output, and emits one
## bit-identical binary per build.
##
## ## Artifact
##
## A single executable, ``/usr/bin/reproos-installer``. The
## ``reproos-installer-launcher`` shell script lives separately in
## ``recipes/reproos-iso/scripts/stage-de-rootfs.sh`` (M9.R.18.1); the
## launcher execs ``reproos-installer`` once the binary lands in the
## live rootfs.
##
## ## v0.1 scope (closed by M9.R.19)
##
## v0.1 declares the recipe shape -- the buildDeps quartet, the
## cmake_package call, the executable artifact -- and runs end-to-end
## via the c_cpp_cmake convention.  M9.R.19 closed the integration:
##
##   * M9.R.19.1 landed ``recipes/packages/source/qt6-quickcontrols2/``
##     so the engine resolves the buildDep selector.
##   * M9.R.19.2 ran this recipe via the engine, producing
##     ``.repro/output/install/usr/bin/reproos-installer``.
##   * M9.R.19.3 wired the binary into the live ISO via
##     ``recipes/reproos-iso/scripts/stage-de-rootfs.sh`` (the
##     overlay is now mandatory, no env-var gate).
##   * M9.R.19.4 flipped the SDDM autologin Session= to
##     ``reproos-installer`` so the live ISO boots straight into the
##     wizard.
##
## ## Build shape
##
## The c_cpp_cmake convention (M9.K) reads the ``cmakeFlags:`` channel
## and the cmake_package call body and lowers them into:
##
##   1. a cmake configure BuildAction against ``./CMakeLists.txt``.
##   2. a ninja compile BuildAction.
##   3. an install BuildAction populating ``$out/usr/bin/reproos-installer``
##      + ``$out/usr/share/reproos-installer/activities.toml``.
##
## The source tree is the recipe directory itself -- no fetch step
## (this is in-tree code, not a vendored upstream).

import std/[os, strutils]

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package reproosInstaller:
  ## In-tree CMake-driven Qt6/QML application. No ``fetch:`` block --
  ## the source lives at ``apps/reproos-installer/`` and the engine
  ## fingerprints the recipe directory contents directly.

  versions:
    ## v0.1 is the M9.R.18 cut: 8 navigable screens, inline activity
    ## catalog, stub install pipeline. v0.2 (M9.R.19) wires the M82
    ## broker for the destructive install step + loads the activity
    ## catalog from /usr/share/reproos-installer/activities.toml.
    "0.1.0":
      sourceRevision = "M9.R.18.4"
      sourceUrl = "in-tree:apps/reproos-installer"
      sourceRepository = "https://github.com/metacraft-labs/reprobuild"

  nativeBuildDeps:
    ## cmake is the build-system driver; the c_cpp_cmake convention's
    ## configure action invokes ``cmake -S . -B <build>`` against the
    ## CMakeLists.txt in this directory.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## gcc is the host C++ toolchain; the installer is C++17.
    "gcc >=11"

  buildDeps:
    ## qt6-base supplies QtCore + QtGui + QtDBus. Same minimum as the
    ## sddm + plasma-workspace recipes (Plasma 6.x line).
    "qt6-base >=6.6"
    ## qt6-declarative supplies QtQml + QtQuick. The wizard's UI lives
    ## entirely in QML so this is the load-bearing dependency.
    "qt6-declarative >=6.6"
    ## qt6-tools supplies lupdate / lrelease (the M9.R.19 i18n pass
    ## will consume them; v0.1 ships English strings inline per PRD
    ## Sec 7.6).
    "qt6-tools >=6.6"
    ## qt6-quickcontrols2 supplies libQt6QuickControls2.so the wizard
    ## QML scenes consume (Button / ComboBox / TextField / ScrollView /
    ## TextArea / ProgressBar / CheckBox).  Recipe lives at
    ## ``recipes/packages/source/qt6-quickcontrols2/`` and builds from
    ## the shared qtdeclarative tarball (QuickControls2 was merged into
    ## qtdeclarative at Qt 6.2; the standalone qtquickcontrols2-
    ## everywhere-src-<ver>.tar.xz tarball returns HTTP 404 from
    ## download.qt.io).  M9.R.19.1 landed the recipe.
    "qt6-quickcontrols2 >=6.6"

  config:
    discard

  executable `reproos-installer`:
    ## ``/usr/bin/reproos-installer`` -- the wizard binary. The kiosk
    ## launcher script (``/usr/bin/reproos-installer-launcher``, shipped
    ## by recipes/reproos-iso M9.R.18.1) execs this binary in a sway
    ## kiosk session.
    discard

  build:
    ## c_cpp_cmake convention call. The CMakeLists.txt in this directory
    ## is the source of truth for the build; the recipe layer just wires
    ## the configure flags + tells the engine what artifact to expect.
    setCurrentOwningPackageOverride("reproosInstaller")
    try:
      let opts = @[
        # CMake 4.x compatibility -- the local CMakeLists already
        # declares min 3.16, but the from-source cmake-4.x in the
        # store needs the policy-version pin to accept legacy 3.x
        # behaviour. Same pattern as the sddm / kwin recipes.
        "CMAKE_POLICY_VERSION_MINIMUM=3.16",
        "CMAKE_BUILD_TYPE=Release",
        # PRD Sec 7.1 -- Wayland-native. The runtime QPA plugin is
        # picked up at exec time from the from-source qt6-base
        # install; no extra cmake flag needed here.
      ]
      let pkg = cmake_package(srcDir = ".", cacheVars = opts)
      discard pkg.executable("reproos-installer")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.19): once the recipe builds end-to-end, populate the
    ## runtime closure from DT_NEEDED inspection (libQt6Core, libQt6Gui,
    ## libQt6Qml, libQt6Quick, libQt6QuickControls2, plus their wayland
    ## QPA plugin transitive deps).
    discard

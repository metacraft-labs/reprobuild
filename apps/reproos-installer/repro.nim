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
## ## v0.1 scope vs M9.R.19 closure
##
## v0.1 (this commit) declares the recipe shape -- the buildDeps trio,
## the cmake_package call, the executable artifact. The actual integrated
## build is gated on the qt6-quickcontrols2 recipe landing in
## ``recipes/packages/source/`` (the existing qt6-declarative covers
## QtQuick + QtQml, but the Controls 2 module ships separately upstream).
## M9.R.19 lands that recipe + runs this recipe end-to-end + wires the
## installed binary into the reproos-iso DE-rootfs union via
## ``stage-de-rootfs.sh`` so the live ISO's autologin session can exec it.
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
    ## qt6-quickcontrols2 -- TODO(M9.R.19): the upstream Qt6 Controls 2
    ## module is not yet packaged as a from-source recipe in this tree.
    ## The wizard UI uses Button / ComboBox / TextField / ScrollView /
    ## TextArea / ProgressBar / CheckBox -- all in QtQuickControls2.
    ## M9.R.19 lands the missing recipe + flips this line to the
    ## from-source dependency.
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

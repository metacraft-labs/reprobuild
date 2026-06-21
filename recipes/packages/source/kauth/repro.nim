## Source-from-tarball kauth recipe — M9.R.15p.4.1 KF6/Plasma
## blocker. kauth supplies the KF6 privileged-action layer kio's
## ``find_package(KF6Auth ${KF_DEP_VERSION} REQUIRED)`` (gated on
## UNIX AND NOT ANDROID) consumes for elevated file-protocol
## operations (trash-empty-as-root, mount-as-root, system-wide
## settings writes).
##
## sha256 = be25601b91b129a48e497231be2513a1eb8c9707a82d38395561656d1df10988
##  (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  kauth-6.10.0.tar.xz.sha256; verified against the vendored
##  2,296,748-byte tarball at
##  ``recipes/packages/source/kauth/vendor/kauth-6.10.0.tar.xz``).
##
## ## Version choice — 6.10.0 (matches sibling KF6 modules)
##
## Same lockstep ABI rationale as the other KF6 6.10.x modules
## (kxmlgui / kpackage / kcrash / kirigami / etc.) — KDE Frameworks
## 6.10.x is the current upstream stable in the 6.x line and the
## recipes track a single tag-set for cross-module ABI compatibility.
##
## ## Backend choice — FAKE
##
## kauth ships three backends (POLKITQT6-1 / FAKE / OSX); FAKE is
## the no-op backend that compiles without a system Polkit library.
## v1 targets a from-source closure that doesn't yet include
## ``polkit-qt-1`` (it would add a multi-recipe pull from
## https://invent.kde.org/libraries/polkit-qt-1, plus polkit itself
## which has its own systemd / dbus / pam closure). The FAKE backend
## still produces a fully-linked ``libKF6AuthCore.so`` + the CMake
## targets needed by kio's ``find_package(KF6Auth)``; the runtime
## behavior is "no privileged action ever succeeds" which is
## acceptable for the v1 KDE Plasma desktop story (kio still loads,
## the privileged operations fail gracefully).
##
## ## Build shape
##
## c_cpp_cmake convention (M9.K) — same as the sibling KF6 / Qt6
## recipes. The CMake build emits ``libKF6AuthCore.so`` + the
## ``KF6Auth`` CMake-config consumed by kio.
##
## ## Library artifact
##
## kauth's main shared library is ``libKF6AuthCore.so`` (the
## "AuthCore" suffix is upstream's naming for the core lib; the
## CMake package name is just ``KF6Auth``). We register the artifact
## under ``libKF6AuthCore`` (camelCased from the upstream SONAME
## ``KF6AuthCore``).
##
## ## Configurables
##
## v1 sets ``KAUTH_BACKEND_NAME=FAKE`` explicitly, plus the same
## modern-desktop baseline as the sibling KF6 recipes
## (``BUILD_TESTING=OFF`` + ``BUILD_QCH=OFF`` +
## ``CMAKE_BUILD_TYPE=Release``).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package kauthSource:
  ## From-source kauth — M9.R.15p.4.1 KF6/Plasma blocker. Tier-2b
  ## c_cpp_cmake convention consumer. Single library artifact recipe.
  ## M9.R.15p.0's package-macro auto-injection handles libxkbcommon +
  ## mesa transparently for all qt6-* consumers.

  versions:
    ## Pinned upstream tag.
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kauth-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kauth"

  fetch:
    ## Vendored tarball; URL records the canonical download.kde.org
    ## upstream so the engine's fetch cache is content-addressed by
    ## sha256.
    url: "https://download.kde.org/stable/frameworks/6.10/kauth-6.10.0.tar.xz"
    sha256: "be25601b91b129a48e497231be2513a1eb8c9707a82d38395561656d1df10988"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — kauth is C++17.
    "gcc >=11"
    ## qt6-tools supplies qhelpgenerator (QCH doc generation).
    "qt6-tools >=6.6"

  buildDeps:
    ## extra-cmake-modules is the KF6 CMake macros + find-modules
    ## library kauth's CMakeLists.txt:8 invokes via
    ## ``find_package(ECM 6.10.0 REQUIRED NO_MODULE)``.
    "extra-cmake-modules >=6.0"
    ## qt6-base supplies QtCore / QtGui / QtDBus the kauth
    ## ``CMakeLists.txt:34`` ``find_package(Qt6 ... CONFIG REQUIRED
    ## Gui)`` consumes (Gui also pulls Core + DBus transitively).
    "qt6-base >=6.6"
    ## kcoreaddons is the KF6 foundation library kauth's
    ## ``CMakeLists.txt:50`` ``find_package(KF6CoreAddons REQUIRED)``
    ## consumes for ``KPluginFactory`` + ``KAboutData`` glue.
    "kcoreaddons >=6.0"
    ## M9.R.15p.0.2 — libxkbcommon + mesa are auto-injected by the
    ## package macro for every qt6-* consumer (see
    ## ``m9r15pAutoInjectQt6Transitive``); no explicit per-recipe
    ## declarations needed.

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the
    ## `build:` block.
    discard

  library libKF6AuthCore:
    ## ``libKF6AuthCore.so`` — the core kauth shared library exposed
    ## as the ``KF6::AuthCore`` CMake target via the ``KF6Auth``
    ## package config. v1 records the artifact only.
    discard

  build:
    ## M9.R.15p.4.1 — explicit `build:` block invoking the
    ## ``cmake_package(...)`` high-level constructor. KAUTH_BACKEND_NAME
    ## is pinned to FAKE so the configure step doesn't trip on a
    ## missing PolkitQt6-1 dep (see the doc block above for rationale).
    setCurrentOwningPackageOverride("kauthSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "CMAKE_BUILD_TYPE=Release",
        "KAUTH_BACKEND_NAME=FAKE",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6AuthCore")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until the
    ## M9.R.5b per-recipe pass populates per-output ELF interrogation.
    discard

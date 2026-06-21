## Source-from-tarball qt6-wayland recipe — M9.R.15p.1.1 KF6/Plasma
## blocker. qt6-wayland supplies Qt6's Wayland integration layer:
##
##   * ``libQt6WaylandClient.so``                    — the Wayland-client
##     library KF6's kwindowsystem links against for window-management
##     hints + transient parents on Wayland sessions. Without it
##     ``find_package(Qt6WaylandClient REQUIRED)`` fails and the
##     kwindowsystem → kio → plasma-framework chain can't link.
##   * ``libQt6WaylandCompositor.so``                — the Wayland-
##     compositor library kwin's Wayland backend embeds for its
##     compositor protocol stack.
##   * ``libQt6WaylandEglClientHwIntegration.so``    — the EGL-client
##     hardware-integration plugin Qt's Wayland client uses to share
##     buffers with the GPU through Mesa's EGL stack.
##
## ## sha256 strategy
##
## We vendor the upstream 6.8.1 .tar.xz at
## ``recipes/packages/source/qt6-wayland/vendor/qtwayland-everywhere-src-6.8.1.tar.xz``
## and reference it via the upstream download.qt.io URL. The 1.1-MiB
## tarball is well under GitHub's 100-MB single-file ceiling so
## vendoring is safe; sibling Qt6 modules (qt6-base 48 MiB, qt6-tools
## 10 MiB, qt6-declarative 36 MiB, qt6-svg 2 MiB, qt6-shadertools 1 MiB)
## vendor similarly.
##
## sha256 = 2226fbde4e2ddd12f8bf4b239c8f38fd706a54e789e63467dfddc77129eca203
##  (computed locally over the vendored
##  ``qtwayland-everywhere-src-6.8.1.tar.xz``, 1,134,428 bytes;
##  downloaded once from the upstream URL recorded in ``versions:``
##  below; cross-checked against the upstream HTTP Digest: SHA-256
##  header on download.qt.io's HEAD response —
##  ``SHA-256=Iib73k4t3RL4v0sjnI84/XBqVOeJ5jRn393HcSnsogM=`` base64-
##  decoded to the same hex digest above).
##
## ## Version choice — 6.8.1 (matches qt6-base + qt6-tools + qt6-declarative + qt6-svg + qt6-shadertools)
##
## qt6-wayland is a coordinated Qt6 release sibling to qt6-base; the
## 6.8.1 tag matches the rest of the Qt6 batch. The Qt module set is
## built as a coordinated release so cross-module ABI matches
## tag-for-tag.
##
## ## Build shape
##
## The c_cpp_cmake convention (M9.K) reads the M9.H ``fetch:`` block
## and the inlined ``cmake_package`` flags and lowers them into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 +
##      extract dest.
##   2. a ``cmake`` configure BuildAction.
##   3. a ``cmake --build`` compile BuildAction.
##   4. install/output collection actions for the three library
##      artifacts.
##
## ## Library artifacts
##
## qt6-wayland's CMake build emits three load-bearing shared libraries
## that the v1 desktop story consumes through the KF6/Plasma chain:
##
##   * ``libQt6WaylandClient.so`` — the Wayland-client library
##                                    kwindowsystem (and through it kio +
##                                    plasma-framework + kwin) link
##                                    against.
##   * ``libQt6WaylandCompositor.so`` — the Wayland-compositor library
##                                        kwin's Wayland backend embeds.
##   * ``libQt6WaylandEglClientHwIntegration.so`` — the EGL-client
##                                                    hardware-integration
##                                                    plugin Qt's Wayland
##                                                    client uses for GPU
##                                                    buffer sharing.
##
## ## Configurables
##
## v1 ships NO configurables — the CMake options are hardcoded to the
## modern-desktop baseline:
##
##   * ``BUILD_TESTING=OFF``        — skip the upstream test suite to
##                                     keep the build hermetic + fast.
##   * ``CMAKE_BUILD_TYPE=Release`` — release-mode optimisation;
##                                     matches sibling qt6-base /
##                                     qt6-tools / qt6-declarative /
##                                     qt6-svg / qt6-shadertools recipes.
##   * ``QT_BUILD_TESTS=OFF``       — Qt-side test-build disable.
##   * ``QT_BUILD_EXAMPLES=OFF``    — skip the upstream examples build.
##   * ``QT_GENERATE_SBOM=OFF``     — SBOM gen hard-codes the canonical
##                                     install prefix and fails when our
##                                     cmake_package install passes a
##                                     different ``--prefix``. Same trip
##                                     as qt6-base / qt6-tools /
##                                     qt6-declarative / qt6-svg /
##                                     qt6-shadertools.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result
import repro_dsl_stdlib/packages/system_tools

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package qt6WaylandSource:
  ## From-source qt6-wayland — M9.R.15p.1.1 KF6/Plasma blocker. Sibling
  ## to qt6-base, qt6-tools, qt6-declarative, qt6-svg, qt6-shadertools;
  ## shares the same 6.8.1 pin.
  ##
  ## Tier-2b c_cpp_cmake convention consumer. Three-library artifact
  ## recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.qt.io release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the same upstream URL.
    ##
    ## ``sourceRepository`` points at the canonical invent.kde.org
    ## qtwayland git repository (Qt6's modular submodules are mirrored
    ## at both code.qt.io and invent.kde.org; the latter is the
    ## currently-canonical home as documented in the M9.R.15p.1 brief).
    "6.8.1":
      sourceRevision = "v6.8.1"
      sourceUrl = "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtwayland-everywhere-src-6.8.1.tar.xz"
      sourceRepository = "https://invent.kde.org/qt/qt/qtwayland"

  fetch:
    ## Vendored tarball. ``url`` records the upstream download.qt.io
    ## URL; the engine's fetch cache is content-addressed by sha256 so
    ## the local vendored copy hits the cache deterministically.
    ##
    ## sha256 computed over the vendored 1,134,428-byte tarball.
    url: "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtwayland-everywhere-src-6.8.1.tar.xz"
    sha256: "2226fbde4e2ddd12f8bf4b239c8f38fd706a54e789e63467dfddc77129eca203"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver — qt6-wayland 6.8.x requires
    ## cmake 3.16 floor (matches the broader Qt6 6.8.1 cmake floor).
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## perl is needed by qt6-wayland's syncqt helper script
    ## (forwarding headers + module-header generation, same pattern as
    ## qt6-base / qt6-tools / qt6-declarative / qt6-svg / qt6-shadertools).
    "perl"
    ## python is invoked by Qt's syncqt + code-generation helpers.
    "python3"
    ## qt6-tools supplies ``qhelpgenerator`` for QCH generation (the Qt
    ## docs-build helper). Matches the sibling qt6-svg / qt6-declarative
    ## native dep set.
    "qt6-tools >=6.8"
    ## wayland-scanner is the protocol-stub code generator qt6-wayland's
    ## CMake build invokes to generate ``*-protocol.c`` /
    ## ``*-protocol-client.h`` files from wayland XML at build time.
    "wayland-scanner"

  buildDeps:
    ## qt6-base supplies QtCore + QtGui + QtNetwork + QtDBus C++
    ## underpinnings — qt6-wayland links against QtCore + QtGui for
    ## every emitted library.
    "qt6-base >=6.8"
    ## qt6-declarative supplies Qt6Qml + Qt6Quick which qt6-wayland's
    ## Wayland client-side QtQuick integration links against for
    ## scene-graph rendering on Wayland windows. Without it the
    ## libQt6WaylandClient build's QtQuick-style sub-components fail to
    ## link.
    "qt6-declarative >=6.8"
    ## wayland supplies libwayland-client + libwayland-server which
    ## qt6-wayland's client + compositor libraries link against.
    "wayland >=1.21"
    ## wayland-protocols ships the XML protocol descriptions
    ## wayland-scanner consumes at build time (xdg-shell, presentation-
    ## time, viewporter, etc.).
    "wayland-protocols >=1.30"
    ## M9.R.15p.0.2 — libxkbcommon + mesa are auto-injected by the
    ## package macro for every qt6-* consumer (see
    ## ``m9r15pAutoInjectQt6Transitive``); no explicit per-recipe
    ## declarations needed.

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the
    ## `build:` block.
    discard

  library libQt6WaylandClient:
    ## ``libQt6WaylandClient.so`` — Qt's Wayland-client library; the
    ## artifact kwindowsystem's ``find_package(Qt6WaylandClient
    ## REQUIRED)`` resolves against. v1 records the artifact only.
    discard

  library libQt6WaylandCompositor:
    ## ``libQt6WaylandCompositor.so`` — Qt's Wayland-compositor library;
    ## kwin's Wayland backend embeds it for its compositor protocol
    ## stack. v1 records the artifact only.
    discard

  library libQt6WaylandEglClientHwIntegration:
    ## ``libQt6WaylandEglClientHwIntegration.so`` — Qt's EGL-client
    ## hardware-integration plugin; Qt's Wayland client uses it to share
    ## buffers with the GPU through Mesa's EGL stack. v1 records the
    ## artifact only.
    discard

  build:
    ## M9.R.15p.1.1 — explicit `build:` block invoking the
    ## ``cmake_package(...)`` high-level constructor.
    setCurrentOwningPackageOverride("qt6WaylandSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
        "QT_BUILD_TESTS=OFF",
        "QT_BUILD_EXAMPLES=OFF",
        # M9.R.15p.1.1 — Qt6's SBOM module hard-codes
        # ``/usr/local/Qt-6.8.1`` as the canonical install prefix when
        # computing per-artifact checksums (same trip as qt6-base
        # M9.R.15f.3 + qt6-tools M9.R.15h.1.4 + qt6-declarative
        # M9.R.15j.1 + qt6-svg M9.R.15k.1 + qt6-shadertools M9.R.15n.2).
        # The ``cmake --install --prefix <buildDir>/out/usr`` we emit
        # doesn't match the baked-in prefix, so install fails with
        # "Cannot find <file> to compute its checksum". Disable SBOM
        # gen for v1.
        "QT_GENERATE_SBOM=OFF",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libQt6WaylandClient")
      discard pkg.library("libQt6WaylandCompositor")
      discard pkg.library("libQt6WaylandEglClientHwIntegration")
    finally:
      clearCurrentOwningPackageOverride()

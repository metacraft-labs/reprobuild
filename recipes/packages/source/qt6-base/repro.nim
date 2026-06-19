## Source-from-tarball qt6-base recipe — the TWENTY-SIXTH real from-
## source production recipe to exercise the M9.H/I/K trio
## (fetch: + cmakeFlags: + convention-layer fetch-action emission).
##
## Prior twenty-five from-source recipes — sixteen meson (dbus-broker,
## libdrm, wayland, wlroots, sway, libxkbcommon, pixman, libinput, cairo,
## pango, gdk-pixbuf, glib2, mutter, gnome-shell, harfbuzz this batch),
## one make (linux-kernel), five CMake (json-c, kcoreaddons, kwin,
## plasma-workspace, sddm), four autotools (expat, gdm, freetype this
## batch, fontconfig this batch) — collectively covered every M9.I
## flag-injection channel. qt6-base is the SIXTH CMake-driven recipe
## and the FIRST recipe in the corpus to ship SIX library artifacts
## from a single ``package`` macro. Every prior multi-artifact recipe
## shipped either two (most multi-artifact recipes) or three (sddm) or
## four (glib2); qt6-base pushes the artifact-name partitioning to six,
## stressing the M3 registry's ability to keep six distinct
## ``dakLibrary`` entries disambiguated within a single package's
## artifact set.
##
## ## Why qt6-base matters for the v1 desktop story
##
## qt6-base is the bottom of the Qt6 dependency graph: QtCore (event
## loop, signals/slots, containers, JSON), QtGui (windowing system
## abstraction, painting, accessibility), QtWidgets (the desktop widget
## set used by Plasma System Settings + KCMs), QtNetwork (HTTP/TCP
## client+server, SSL), QtDBus (D-Bus binding used by Plasma's
## inter-service plumbing), QtSql (DB driver framework used by
## KConfigData + Plasma activities). Every KF6 module + every Plasma
## component links against qt6-base; the sibling ``kcoreaddonsSource``
## and ``kwinSource`` recipes pin ``qt6-base >=6.6`` in their ``uses:``
## blocks. The mutter + gnome-shell stack also picks up qt6-base
## transitively via the SDDM greeter QML runtime.
##
## ## sha256 strategy
##
## We vendor the upstream qtbase-everywhere-src-6.8.1 .tar.xz at
## ``recipes/packages/source/qt6-base/vendor/qtbase-everywhere-src-6.8.1.tar.xz``
## and reference it via a ``file://`` URL. At 48,220,752 bytes the
## tarball is well under GitHub's 100-MB single-file ceiling so
## vendoring is safe (kernel-style upstream-URL fallback would only be
## warranted above ~90 MB). The download.qt.io release URL is recorded
## as ``sourceUrl`` in the ``versions:`` block for documentation and
## future-bump purposes, but the live ``fetch:`` block points at the
## vendored copy so the convention layer's emitted fetch action is
## offline-reproducible.
##
## ## Version choice — 6.8.1 (current upstream LTS-leading)
##
## download.qt.io publishes Qt6 modular submodule sources at
## ``https://download.qt.io/official_releases/qt/<major.minor>/<version>/submodules/``
## and 6.8.1 is the current stable in the 6.8.x line as of mid-2026.
## The 6.x ABI compatibility is maintained across 6.6 -> 6.7 -> 6.8 so
## the ``qt6-base >=6.6`` floor in the KF6 / kwin / kcoreaddons recipes
## is fully satisfied by 6.8.1.
##
## sha256 = 40b14562ef3bd779bc0e0418ea2ae08fa28235f8ea6e8c0cb3bce1d6ad58dcaf
##  (computed locally over the vendored
##  ``qtbase-everywhere-src-6.8.1.tar.xz``, 48,220,752 bytes; downloaded
##  once from the upstream URL recorded in ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_cmake convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``cmakeFlags:`` block off this package's
## registries and lowers them into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 +
##      extract dest (content-addressed so a re-run hits the cache).
##   2. a ``cmake`` configure BuildAction that depends on the fetch
##      action and passes every flag in ``cmakeFlags:`` to
##      ``cmake -S <src> -B <build>``, in declared order.
##   3. a ``ninja`` (or ``cmake --build``) compile BuildAction (M9.L).
##   4. install/output collection actions for the six library artifacts
##      (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ninja-spawn + install glue lands in M9.L; the recipe
## records all six library artifacts via the ``library`` blocks so the
## M9.K artifact registry already knows what shared objects to expect.
##
## ## Library artifacts
##
## qt6-base's CMake build emits six load-bearing shared libraries that
## the v1 desktop story consumes:
##
##   * ``libQt6Core.so``    — the event loop + signals/slots + container
##                             foundation every Qt-using app links.
##   * ``libQt6Gui.so``     — the windowing system abstraction + painting
##                             + accessibility layer.
##   * ``libQt6Widgets.so`` — the desktop widget set used by Plasma
##                             System Settings + KCM modules.
##   * ``libQt6Network.so`` — the HTTP/TCP client+server + SSL stack
##                             used by Plasma + KIO.
##   * ``libQt6DBus.so``    — the D-Bus binding used by Plasma's
##                             inter-service plumbing + KNotifications.
##   * ``libQt6Sql.so``     — the DB driver framework used by
##                             KConfigData + Plasma activities (SQLite
##                             driver enabled via FEATURE_sql_sqlite).
##
## We register the artifacts under the package-level identifiers
## ``libQt6Core`` / ``libQt6Gui`` / ``libQt6Widgets`` / ``libQt6Network``
## / ``libQt6DBus`` / ``libQt6Sql`` (preserving the upstream PascalCase
## SONAME naming convention; matches the json-c / kcoreaddons precedent
## of preserving library-style PascalCase identifiers when the upstream
## SONAME is already PascalCase).
##
## We intentionally do NOT register the auxiliary
## ``libQt6OpenGL.so`` / ``libQt6PrintSupport.so`` / ``libQt6Test.so``
## / ``libQt6Concurrent.so`` / ``libQt6Xml.so`` — they're not on the
## v1 desktop critical path (Plasma uses QtQuick scene-graph which is
## in qt6-declarative, not qt6-base's QtOpenGL; printing isn't in v1;
## QtTest is build-time; QtConcurrent + QtXml are pulled in transitively
## via QtCore / QtGui).
##
## ## Configurables
##
## v1 ships NO configurables — the CMake options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``BUILD_TESTING=OFF``          — skip the upstream test suite to
##                                       keep the build hermetic + fast.
##   * ``CMAKE_BUILD_TYPE=Release``   — release-mode optimisation;
##                                       matches the sibling from-source
##                                       recipes.
##   * ``FEATURE_developer_build=OFF`` — disable the upstream
##                                       developer-build mode which
##                                       enables extra debug helpers +
##                                       warnings-as-errors.
##   * ``FEATURE_xcb=OFF``            — drop X11/XCB support (the v1
##                                       desktop story is pure-Wayland;
##                                       Plasma + GNOME both ship
##                                       Wayland sessions only).
##   * ``FEATURE_dbus=ON``            — enable the D-Bus binding (used
##                                       by Plasma + KNotifications +
##                                       inter-service plumbing).
##   * ``FEATURE_sql_sqlite=ON``      — enable the SQLite SQL driver
##                                       (used by KConfigData + Plasma
##                                       activities).
##   * ``FEATURE_widgets=ON``         — enable the QtWidgets desktop
##                                       widget set (used by Plasma
##                                       System Settings + KCM modules).
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. an X11-supporting variant
## that flips ``FEATURE_xcb=ON`` for legacy bundles).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package qt6BaseSource:
  ## From-source qt6-base — twenty-sixth M9.H/I/K production recipe and
  ## SIXTH CMake-driven recipe (json-c, kcoreaddons, kwin,
  ## plasma-workspace, sddm precedents). FIRST recipe in the corpus to
  ## ship SIX library artifacts from a single ``package`` macro.
  ##
  ## Tier-2b c_cpp_cmake convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``cmakeFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"cmake"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right URL +
  ## hash + flags. Six library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.qt.io release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical code.qt.io qtbase
    ## git repository — qt6-base's canonical home.
    "6.8.1":
      sourceRevision = "v6.8.1"
      sourceUrl = "https://download.qt.io/official_releases/qt/6.8/6.8.1/submodules/qtbase-everywhere-src-6.8.1.tar.xz"
      sourceRepository = "https://code.qt.io/qt/qtbase.git"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan). At
    ## 48 MB the tarball is well under GitHub's 100-MB single-file
    ## ceiling so vendoring is safe; the kernel-style upstream-URL
    ## fallback would only be warranted above ~90 MB.
    ##
    ## ``file://`` URL keeps the build deterministic when the network is
    ## unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 48,220,752-byte tarball
    ## downloaded once from the upstream URL recorded in ``versions:``
    ## above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/qt6-base/vendor/qtbase-everywhere-src-6.8.1.tar.xz"
    sha256: "40b14562ef3bd779bc0e0418ea2ae08fa28235f8ea6e8c0cb3bce1d6ad58dcaf"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver — the c_cpp_cmake convention's
    ## configure action invokes ``cmake -S <src> -B <build>``. qt6-base
    ## 6.8.x requires cmake 3.21 for the modern qt-internal-build helper
    ## macros that drive the per-feature module gating.
    "cmake >=3.21"
    ## ninja is CMake's preferred backend on Linux — the compile action
    ## invokes ``ninja`` (or ``cmake --build``) against the CMake build
    ## directory.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — qt6-base is C++17 with light
    ## use of C++20 features in the QtCore signals/slots upgrade path.
    "gcc >=11"
    ## perl is needed by qt6-base's syncqt helper script which generates
    ## the public-header forwarding layer at configure time.
    "perl >=5.32"
    ## pkg-config is used by the CMake configure step to probe for the
    ## wayland / freetype / fontconfig / harfbuzz / libdbus / sqlite /
    ## libssl / zlib dependencies.
    "pkg-config"

  buildDeps:
    ## python is invoked by qt6-base's QML compiler driver + a handful
    ## of code-generation helpers in the build.
    "python >=3.8"
    ## glib is consumed transitively via QtGui's wayland-client glue
    ## (qtwayland would be the proper consumer but qt6-base's QPA
    ## abstraction probes for the wayland-protocols pkgconfig at build
    ## time).
    "glib >=2.62"
    ## libxkbcommon supplies the keyboard-keymap library QtGui's QPA
    ## Wayland backend uses for layout switching + compose-key handling.
    ## The sibling ``libxkbcommonSource`` recipe vendors a compatible
    ## version.
    "libxkbcommon >=1.5"
    ## wayland supplies libwayland-client + the wayland-protocols
    ## scanner QtGui's QPA Wayland backend uses to draw on the
    ## compositor display. The sibling ``waylandSource`` recipe vendors
    ## a compatible version.
    "wayland >=1.20"
    ## freetype is the glyph rasteriser QtGui consumes for text-render
    ## fallback when the host fontconfig doesn't return a suitable
    ## font. The sibling ``freetypeSource`` recipe vendors 2.13.3.
    "freetype >=2.10"
    ## fontconfig is the font-discovery + matching layer QtGui consumes
    ## to resolve QFont(...) family-names to actual files on disk. The
    ## sibling ``fontconfigSource`` recipe vendors 2.16.0.
    "fontconfig >=2.13"
    ## harfbuzz is the OpenType text-shaping engine QtGui consumes for
    ## complex-script rendering (Arabic, Hebrew, Devanagari, CJK). The
    ## sibling ``harfbuzzSource`` recipe vendors 10.1.0.
    "harfbuzz >=4.0"
    ## libdbus is the D-Bus client library QtDBus binds to — the
    ## upstream libdbus-1 reference implementation.
    "libdbus >=1.14"
    ## sqlite supplies the SQLite SQL driver QtSql loads when the
    ## ``FEATURE_sql_sqlite=ON`` flag is set.
    "sqlite >=3.40"
    ## libssl is consumed by QtNetwork for HTTPS / TLS support.
    "libssl >=3.0"
    ## zlib supplies the deflate / inflate primitives QtCore +
    ## QtNetwork consume for HTTP compression + QFile transparent
    ## decompression.
    "zlib >=1.2.11"

  cmakeFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: CMake evaluates ``-D`` overrides
    ## left-to-right and the ``CMAKE_BUILD_TYPE=Release`` sentinel
    ## lives at the head (alongside ``BUILD_TESTING=OFF``) for the
    ## hermetic-build pin, followed by the ``FEATURE_*`` per-feature
    ## flags in alphabetical order so a future maintainer can grep for
    ## ``FEATURE_X`` without scanning the whole block.
    ##
    ## ``BUILD_TESTING=OFF`` skips the upstream test suite.
    ## ``CMAKE_BUILD_TYPE=Release`` enables release-mode optimisation.
    ## ``FEATURE_developer_build=OFF`` disables the upstream dev-build
    ##  mode.
    ## ``FEATURE_xcb=OFF`` drops X11/XCB support (v1 is pure-Wayland).
    ## ``FEATURE_dbus=ON`` enables the QtDBus module.
    ## ``FEATURE_sql_sqlite=ON`` enables the QtSql SQLite driver.
    ## ``FEATURE_widgets=ON`` enables the QtWidgets desktop widget set.
    "-DBUILD_TESTING=OFF"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DFEATURE_developer_build=OFF"
    "-DFEATURE_xcb=OFF"
    "-DFEATURE_dbus=ON"
    "-DFEATURE_sql_sqlite=ON"
    "-DFEATURE_widgets=ON"

  library libQt6Core:
    ## ``libQt6Core.so`` — the event loop + signals/slots + container
    ## foundation every Qt-using app links. v1 records the artifact
    ## only; the per-artifact build body lands in M9.L when the
    ## convention's ninja-spawn + install-glue closes.
    discard

  library libQt6Gui:
    ## ``libQt6Gui.so`` — the windowing system abstraction + painting +
    ## accessibility layer. Drives the QPA Wayland backend on the v1
    ## desktop. v1 records the artifact only.
    discard

  library libQt6Widgets:
    ## ``libQt6Widgets.so`` — the desktop widget set used by Plasma
    ## System Settings + KCM modules. v1 records the artifact only.
    discard

  library libQt6Network:
    ## ``libQt6Network.so`` — the HTTP/TCP client+server + SSL stack
    ## used by Plasma + KIO. v1 records the artifact only.
    discard

  library libQt6DBus:
    ## ``libQt6DBus.so`` — the D-Bus binding used by Plasma's
    ## inter-service plumbing + KNotifications. v1 records the artifact
    ## only.
    discard

  library libQt6Sql:
    ## ``libQt6Sql.so`` — the DB driver framework used by KConfigData
    ## + Plasma activities (SQLite driver enabled via
    ## ``FEATURE_sql_sqlite=ON``). v1 records the artifact only.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

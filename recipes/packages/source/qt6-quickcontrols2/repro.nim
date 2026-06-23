## qt6-quickcontrols2 SHIM recipe -- M9.R.19.1 ReproOS Installer
## blocker.  Re-exports the QuickControls2 artifacts that the sibling
## qt6-declarative recipe already builds, via a deterministic copy.
##
## ## Why this is a shim, not a real build
##
## Two upstream facts collide:
##
##   1. Qt 6 merged QuickControls2 INTO qtdeclarative at Qt 6.2; the
##      standalone qtquickcontrols2-everywhere-src-<ver>.tar.xz tarball
##      that Qt 5 shipped no longer exists upstream
##      (``https://download.qt.io/.../qtquickcontrols2-everywhere-src-
##      6.8.1.tar.xz`` returns HTTP 404, verified 2026-06-23).
##   2. The reprobuild engine's from-source tool resolver requires a
##      sibling recipe at ``recipes/packages/source/<name>/`` per
##      ``uses:`` selector, so the reproos-installer recipe's
##      ``qt6-quickcontrols2 >=6.6`` buildDep must resolve to SOMETHING
##      at this path or the engine hard-fails with
##      "tool-resolution failed: ... but no sibling recipe at ...".
##
## An earlier draft of this recipe tried to build the whole
## qtdeclarative tarball from scratch and declare libQt6QuickControls2
## as its artifact.  That approach DETERMINISTICALLY wedged in
## CMake's ``cmake_autogen`` worker for the
## ``qtquickcontrols2nativestyleplugin_autogen`` target -- a known
## upstream CMake + Qt6 race where the autogen futex-waits after
## producing 51 of 60 moc files for that single target, never reaping
## its moc subprocesses.  The wedge was reproduced across two
## independent eli-wsl runs (M9.R.19.1, M9.R.19.1.2) and is independent
## of the cache state, build parallelism, or env var hygiene.
##
## The honest fix is to stop building qtdeclarative twice.  This recipe
## stages an action that copies the relevant CMake configs + the QML
## plugins + the libraries OUT of the sibling qt6-declarative recipe's
## install-mirror INTO this recipe's install-mirror.  Per the
## from-source tool resolver's M9.R.15p.1.6 "share-only-package
## fast-path" (in ``libs/repro_tool_profiles/src/repro_tool_profiles.nim``),
## the resolver succeeds as soon as
## ``<recipe>/.repro/output/install/usr/lib/cmake/Qt6QuickControls2/
##  Qt6QuickControls2Config.cmake`` exists; the share-only fast-path
## was designed exactly for this shape (KDE's
## ``extra-cmake-modules`` is the canonical share-only-package
## consumer of the same path).
##
## ## Build shape
##
## A single ``shell`` action:
##
##   1. Reads ``recipes/packages/source/qt6-declarative/.repro/output/
##      install/usr/`` as input (extraInputs).
##   2. Copies the QuickControls2 artifacts -- ``libQt6QuickControls2.
##      so*``, ``libQt6QuickTemplates2.so*``, ``libQt6QuickControls2*.
##      so*`` (Basic / Material / Universal / Fusion / Imagine /
##      FluentWinUI3 style impls), the ``lib/cmake/Qt6QuickControls2/``
##      + ``lib/cmake/Qt6QuickTemplates2/`` + the *StyleImpl cmake
##      configs, the ``qml/QtQuick/Controls/`` QML plugins, and the
##      ``include/QtQuickControls2*/`` + ``include/QtQuickTemplates2*/``
##      headers -- into this recipe's ``out/usr/`` tree.
##   3. Stages the resulting tree as the install-mirror.
##
## When qt6-declarative isn't yet built, the action hard-fails with a
## structured diagnostic naming the sibling recipe -- the engine's
## ``uses`` / ``buildDeps`` topological-order pre-resolves qt6-
## declarative before this recipe.

import std/[strutils]

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package qt6QuickControls2Source:
  ## Shim qt6-quickcontrols2 -- M9.R.19.1 ReproOS Installer blocker.
  ## Re-exports qt6-declarative's QuickControls2 artifacts via a
  ## deterministic copy so the from-source tool resolver matches the
  ## reproos-installer recipe's ``qt6-quickcontrols2 >=6.6`` buildDep
  ## without re-building qtdeclarative (avoiding the cmake_autogen
  ## wedge documented in the header).

  defaultToolProvisioning "path"

  versions:
    "6.8.1":
      sourceRevision = "v6.8.1"
      sourceUrl = "in-tree-shim:from-qt6-declarative"
      sourceRepository = "https://code.qt.io/qt/qtdeclarative.git"

  uses:
    "sh"

  build:
    ## The shell action stages from the sibling qt6-declarative recipe's
    ## install mirror.  All paths are relative to the recipe directory
    ## (recipes/packages/source/qt6-quickcontrols2/); ``../../`` reaches
    ## the repo root.
    let qtdeclSrc =
      "../qt6-declarative/.repro/output/install/usr"
    let outRoot = ".repro/output/install/usr"
    let cmd = "set -euo pipefail; " &
      "SRC=" & qtdeclSrc & "; " &
      "DST=" & outRoot & "; " &
      "if [ ! -d \"$SRC\" ]; then " &
      "  echo \"[qt6-quickcontrols2 shim] qt6-declarative install mirror missing at $SRC\" >&2; " &
      "  echo \"[qt6-quickcontrols2 shim] build qt6-declarative first: \\\"repro build recipes/packages/source/qt6-declarative\\\"\" >&2; " &
      "  exit 65; " &
      "fi; " &
      "mkdir -p \"$DST/lib/cmake\" \"$DST/lib\" \"$DST/include\" \"$DST/qml\" \"$DST/libexec\" \"$DST/mkspecs\"; " &
      # CMake configs -- the share-only fast-path probe target.
      "for cfgDir in Qt6QuickControls2 Qt6QuickTemplates2 " &
      "             Qt6QuickControls2Impl " &
      "             Qt6QuickControls2BasicStyleImpl " &
      "             Qt6QuickControls2MaterialStyleImpl " &
      "             Qt6QuickControls2UniversalStyleImpl " &
      "             Qt6QuickControls2FusionStyleImpl " &
      "             Qt6QuickControls2ImagineStyleImpl " &
      "             Qt6QuickControls2FluentWinUI3StyleImpl; do " &
      "  if [ -d \"$SRC/lib/cmake/$cfgDir\" ]; then " &
      "    cp -rL --no-clobber \"$SRC/lib/cmake/$cfgDir\" \"$DST/lib/cmake/\"; " &
      "  fi; " &
      "done; " &
      # Libraries.
      "for lib in $SRC/lib/libQt6QuickControls2*.so* " &
      "           $SRC/lib/libQt6QuickTemplates2*.so* " &
      "           $SRC/lib/libQt6QuickControls2*.prl " &
      "           $SRC/lib/libQt6QuickTemplates2*.prl; do " &
      "  if [ -e \"$lib\" ] || [ -L \"$lib\" ]; then cp -P \"$lib\" \"$DST/lib/\" 2>/dev/null || true; fi; " &
      "done; " &
      # QML plugins -- under qml/QtQuick/Controls.
      "if [ -d \"$SRC/qml/QtQuick/Controls\" ]; then " &
      "  mkdir -p \"$DST/qml/QtQuick\"; " &
      "  cp -rL --no-clobber \"$SRC/qml/QtQuick/Controls\" \"$DST/qml/QtQuick/\"; " &
      "fi; " &
      "if [ -d \"$SRC/qml/QtQuick/Templates\" ]; then " &
      "  cp -rL --no-clobber \"$SRC/qml/QtQuick/Templates\" \"$DST/qml/QtQuick/\"; " &
      "fi; " &
      # Headers.
      "for hdrDir in QtQuickControls2 QtQuickTemplates2 " &
      "              QtQuickControls2Impl " &
      "              QtQuickControls2BasicStyleImpl " &
      "              QtQuickControls2MaterialStyleImpl " &
      "              QtQuickControls2UniversalStyleImpl " &
      "              QtQuickControls2FusionStyleImpl " &
      "              QtQuickControls2ImagineStyleImpl " &
      "              QtQuickControls2FluentWinUI3StyleImpl; do " &
      "  if [ -d \"$SRC/include/$hdrDir\" ]; then " &
      "    cp -rL --no-clobber \"$SRC/include/$hdrDir\" \"$DST/include/\"; " &
      "  fi; " &
      "done; " &
      # Sanity check -- the resolver's load-bearing config file.
      "test -f \"$DST/lib/cmake/Qt6QuickControls2/Qt6QuickControls2Config.cmake\" || { " &
      "  echo \"[qt6-quickcontrols2 shim] expected Qt6QuickControls2Config.cmake not staged at $DST\" >&2; " &
      "  exit 66; " &
      "}; " &
      "echo \"[qt6-quickcontrols2 shim] staged from $SRC -> $DST\""
    shell(
      command = cmd,
      actionId = "qt6QuickControls2Source.shim_stage",
      extraInputs = @[
        # The sibling qt6-declarative install mirror.  Listing it as an
        # extraInput tells the engine to rebuild this shim whenever the
        # sibling's mirror changes.
        "../qt6-declarative/.repro/output/install/usr/lib/cmake/Qt6QuickControls2/Qt6QuickControls2Config.cmake",
      ],
      extraOutputs = @[
        ".repro/output/install/usr/lib/cmake/Qt6QuickControls2/Qt6QuickControls2Config.cmake",
      ])

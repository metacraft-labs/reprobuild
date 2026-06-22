## Source-from-tarball ktexteditor recipe — M9.R.15q.10.3 KF6 cascade
## module. ktexteditor is Tier-3 KDE Frameworks: the Kate editor
## widget library (``libKF6TextEditor.so``).
##
## sha256 = 3f80c4feb8737cef83775e2c79f86060c16af89ee8b48e2d72f94bdc1a180b9f

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package ktexteditorSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/ktexteditor-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/ktexteditor"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/ktexteditor-6.10.0.tar.xz"
    sha256: "3f80c4feb8737cef83775e2c79f86060c16af89ee8b48e2d72f94bdc1a180b9f"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    ## M9.R.15q.10.3 — Qt6TextToSpeech is REQUIRED by ktexteditor's
    ## find_package(Qt6 ... TextToSpeech). Sibling qt6-speech recipe.
    "qt6-speech >=6.8"
    "kparts >=6.0"
    "ki18n >=6.0"
    "kconfig >=6.0"
    "kcoreaddons >=6.0"
    "kconfigwidgets >=6.0"
    "kguiaddons >=6.0"
    "kiconthemes >=6.0"
    "kjobwidgets >=6.0"
    "kio >=6.0"
    "ktextwidgets >=6.0"
    "kxmlgui >=6.0"
    "sonnet >=6.0"
    "syntax-highlighting >=6.0"
    "karchive >=6.0"

  config:
    discard

  library libKF6TextEditor:
    discard

  build:
    setCurrentOwningPackageOverride("ktexteditorSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "CMAKE_BUILD_TYPE=Release",
        # M9.R.15q.10.3 — disable editorconfig integration so we don't
        # need a from-source editorconfig recipe yet. ktexteditor reads
        # the ``ENABLE_EDITORCONFIG`` cache var via standard option().
        "ENABLE_EDITORCONFIG=OFF",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6TextEditor")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard

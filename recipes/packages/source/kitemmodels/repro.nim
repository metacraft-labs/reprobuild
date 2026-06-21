## Source-from-tarball kitemmodels recipe — closes the
## ``KCategorizedSortFilterProxyModel`` find_package gap on kcmutils.
##
## kitemmodels (``libKF6ItemModels.so``) is the KF6 framework that ships
## the Qt model/view ItemModel proxies + helpers — KCategorizedSortFilterProxyModel,
## KConcatenateRowsProxyModel, KDescendantsProxyModel, KSelectionProxyModel.
## kcmutils embeds these proxies into its module-browser dialog.
##
## ## Why kitemmodels matters for the v1 desktop story
##
## kcmutils's KPluginProxyModel inherits from KCategorizedSortFilterProxyModel
## (kcmutils/src/quick/kpluginproxymodel.h:14); without kitemmodels,
## kcmutils's build fails with "KCategorizedSortFilterProxyModel is used
## as base type but cannot be found". kcmutils is the prereq for
## plasma-framework, which is the prereq for kwin/plasma-workspace/sddm.
##
## ## sha256 strategy
##
## We vendor the upstream 6.10.0 .tar.xz at
## ``recipes/packages/source/kitemmodels/vendor/kitemmodels-6.10.0.tar.xz``
## and reference it via the canonical download.kde.org URL.
##
## ## Version choice — 6.10.0
##
## Lockstep with the rest of the KF6 6.10.x recipes.
##
## sha256 = 83859a4aee67bf5e768a93325422264cb9e847013f281c5cb02e631c3b3b0007
##  (computed locally over the vendored ``kitemmodels-6.10.0.tar.xz``,
##  396,632 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## c_cpp_cmake convention (M9.K) — same as the sibling KF6 recipes.
##
## ## Library artifact
##
## kitemmodels's CMake build emits a single shared library
## (``libKF6ItemModels.so``); we register the artifact under
## ``libKF6ItemModels`` (matches the KF6 SONAME).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package kitemmodelsSource:
  ## From-source kitemmodels — M9.R.15q.1.7 production recipe. Closes
  ## the ``KCategorizedSortFilterProxyModel`` find_package gap on
  ## kcmutils. Tier-2b c_cpp_cmake convention consumer. Single library
  ## artifact recipe.

  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kitemmodels-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kitemmodels"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kitemmodels-6.10.0.tar.xz"
    sha256: "83859a4aee67bf5e768a93325422264cb9e847013f281c5cb02e631c3b3b0007"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    ## qt6-base supplies QtCore + QtGui + QtQml the ItemModels proxies
    ## consume (QAbstractItemModel + QML helpers).
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    ## qt6-declarative supplies the QML compiler the QML wrappers
    ## register types through.
    "qt6-declarative >=6.6"

  config:
    discard

  library libKF6ItemModels:
    ## ``libKF6ItemModels.so`` — Qt model/view ItemModel proxies +
    ## helpers (KCategorizedSortFilterProxyModel, etc.). v1 records
    ## the artifact only.
    discard

  build:
    setCurrentOwningPackageOverride("kitemmodelsSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6ItemModels")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard

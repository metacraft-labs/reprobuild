## Source-from-tarball kidletime recipe — M9.R.15h.10 KF6 cascade
## module. kidletime is Tier-1 KDE Frameworks: user-idle detection
## (KIdleTime) backed by the Wayland ext-idle-notify-v1 protocol or
## X11's XScreensaver extension; consumed by Plasma's power
## management + screen-locker.
##
## sha256 = fa25fe866aefd4536022142822ce9856f7a85ffa95070980527de9b31eab0988
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  kidletime-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kidletimeSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kidletime-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kidletime"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kidletime-6.10.0.tar.xz"
    sha256: "fa25fe866aefd4536022142822ce9856f7a85ffa95070980527de9b31eab0988"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"
    "wayland-scanner >=1.22"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "wayland >=1.22"

  config:
    discard

  library libKF6IdleTime:
    discard

  build:
    setCurrentOwningPackageOverride("kidletimeSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
        # WITH_X11=OFF: drop X11 XScreensaver backend; v1 is Wayland.
        "WITH_X11=OFF",
        # M9.R.15q.5.5 — WITH_WAYLAND=OFF: drop the Wayland backend too
        # because the Wayland backend pulls in
        # ``find_package(Qt6WaylandClient REQUIRED)`` +
        # ``find_package(PlasmaWaylandProtocols REQUIRED)``. Neither
        # has a from-source sibling recipe yet (qt6-wayland is the
        # blocker; plasma-wayland-protocols would follow). With BOTH
        # backends off the library compiles a stub that returns
        # idleTime() = 0 — the public API is preserved + the SONAME
        # ships, so downstream consumers (kwin's idle-management
        # plugin) link successfully; the v1 deliverable doesn't need
        # the runtime idle-detection backend wired up yet.
        "WITH_WAYLAND=OFF",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6IdleTime")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard

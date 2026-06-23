## Source-from-tarball xkeyboard-config recipe — M9.R.27.3 Gap 3 prep.
##
## xkeyboard-config is the data archive shipping XKB rules / models /
## layouts / variants. Consumed by libxkbcommon + the X server +
## xwayland at runtime.
##
## Vendored at ``recipes/packages/source/xkeyboard-config/vendor/xkeyboard-config-2.43.tar.xz``.
## sha256 = c810f362c82a834ee89da81e34cd1452c99789339f46f6037f4b9e227dd06c01
## (925,424 bytes).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package xkeyboardConfigSource:
  versions:
    "2.43":
      sourceRevision = "xkeyboard-config-2.43"
      sourceUrl = "https://www.x.org/releases/individual/data/xkeyboard-config/xkeyboard-config-2.43.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xkeyboard-config/xkeyboard-config"

  fetch:
    url: "https://www.x.org/releases/individual/data/xkeyboard-config/xkeyboard-config-2.43.tar.xz"
    sha256: "c810f362c82a834ee89da81e34cd1452c99789339f46f6037f4b9e227dd06c01"
    extractStrip: 1

  nativeBuildDeps:
    "meson >=1.0"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"
    "gettext"
    "python3"

  buildDeps:
    "libxkbcommon"

  config:
    discard

  build:
    setCurrentOwningPackageOverride("xkeyboardConfigSource")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[])
      discard pkg
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard

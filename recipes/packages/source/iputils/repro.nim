## Source-built ping from the upstream iputils release.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package iputilsSource:
  versions:
    "20250605":
      sourceRevision = "20250605"
      sourceUrl = "https://github.com/iputils/iputils/releases/download/20250605/iputils-20250605.tar.xz"
      sourceRepository = "https://github.com/iputils/iputils"

  fetch:
    url: "https://github.com/iputils/iputils/releases/download/20250605/iputils-20250605.tar.xz"
    sha256: "6f213700dbf96b5cc4499ca70cb15ecd69c09f405b06785bb4a1a10b572b6276"
    extractStrip: 1

  nativeBuildDeps:
    "meson"
    "ninja"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    discard

  config:
    discard

  executable ping:
    discard

  build:
    setCurrentOwningPackageOverride("iputilsSource")
    try:
      let opts = @[
        "USE_CAP=false",
        "USE_IDN=false",
        "USE_GETTEXT=false",
        "BUILD_ARPING=false",
        "BUILD_CLOCKDIFF=false",
        "BUILD_TRACEPATH=false",
        "BUILD_MANS=false",
        "NO_SETCAP_OR_SUID=true",
        "SKIP_TESTS=true",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("ping")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard

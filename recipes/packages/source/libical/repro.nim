import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libicalSource:
  versions:
    "3.0.19":
      sourceRevision = "v3.0.19"
      sourceUrl = "https://github.com/libical/libical/releases/download/v3.0.19/libical-3.0.19.tar.gz"
      sourceRepository = "https://github.com/libical/libical"

  fetch:
    url: "https://github.com/libical/libical/releases/download/v3.0.19/libical-3.0.19.tar.gz"
    sha256: "6a1e7f0f50a399cbad826bcc286ce10d7151f3df7cc103f641de15160523c73f"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    "glib2 >=2.70"
    "libxml2 >=2.10"

  config:
    discard

  library libIcal:
    discard
  library libIcalss:
    discard
  library libIcalvcal:
    discard
  library libIcalGlib:
    discard

  build:
    setCurrentOwningPackageOverride("libicalSource")
    try:
      let opts = @[
        "WITH_CXX_BINDINGS=OFF",
        "SHARED_ONLY=ON",
        "GOBJECT_INTROSPECTION=OFF",
        "ICAL_BUILD_DOCS=OFF",
        "ICAL_GLIB_VAPI=OFF",
        "ICAL_GLIB=ON",
        "ENABLE_GTK_DOC=OFF",
        "LIBICAL_BUILD_TESTING=OFF",
        "LIBICAL_BUILD_EXAMPLES=OFF",
        "CMAKE_BUILD_TYPE=Release",
        "CMAKE_POLICY_VERSION_MINIMUM=3.5",
      ]
      let pkg = cmake_package(srcDir = "./src", generator = "Ninja",
        cacheVars = opts, allowSourceWrites = true, extraEnv = @[
          ("CPATH", "/opt/repro/reprobuild/recipes/packages/source/glib2/.repro/output/install/usr/include/glib-2.0:/opt/repro/reprobuild/recipes/packages/source/glib2/.repro/output/install/usr/lib/glib-2.0/include:/opt/repro/reprobuild/recipes/packages/source/libxml2/.repro/output/install/usr/include/libxml2"),
        ])
      discard pkg.library("libIcal")
      discard pkg.library("libIcalss")
      discard pkg.library("libIcalvcal")
      discard pkg.library("libIcalGlib")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    "glib2 >=2.70"
    "libxml2 >=2.10"

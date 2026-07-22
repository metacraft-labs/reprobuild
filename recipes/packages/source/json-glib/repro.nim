import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package jsonGlibSource:
  versions:
    "1.10.8":
      sourceRevision = "1.10.8"
      sourceUrl = "https://download.gnome.org/sources/json-glib/1.10/json-glib-1.10.8.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/json-glib"

  fetch:
    url: "https://download.gnome.org/sources/json-glib/1.10/json-glib-1.10.8.tar.xz"
    sha256: "55c5c141a564245b8f8fbe7698663c87a45a7333c2a2c56f06f811ab73b212dd"
    extractStrip: 1

  nativeBuildDeps:
    "meson >=1.0"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    "glib2 >=2.70"

  config:
    discard

  library libJsonGlib:
    discard

  build:
    setCurrentOwningPackageOverride("jsonGlibSource")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[
        "introspection=disabled",
        "documentation=disabled",
        "man=false",
        "tests=false",
        "conformance=false",
        "nls=disabled",
        "installed_tests=false",
      ])
      discard pkg.library("libJsonGlib")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    "glib2 >=2.70"

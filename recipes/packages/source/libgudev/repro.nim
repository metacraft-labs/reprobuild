import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libgudevSource:
  versions:
    "238":
      sourceRevision = "238"
      sourceUrl = "https://download.gnome.org/sources/libgudev/238/libgudev-238.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/libgudev"
  fetch:
    url: "https://download.gnome.org/sources/libgudev/238/libgudev-238.tar.xz"
    sha256: "61266ab1afc9d73dbc60a8b2af73e99d2fdff47d99544d085760e4fa667b5dd1"
    extractStrip: 1
  nativeBuildDeps:
    "meson >=0.56"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"
  buildDeps:
    "glib2"
    "eudev"
  config:
    discard
  library libgudev:
    discard
  build:
    setCurrentOwningPackageOverride("libgudevSource")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[
        "tests=disabled",
        "introspection=disabled",
        "vapi=disabled",
        "gtk_doc=false",
      ])
      discard pkg.library("libgudev-1.0")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "glib2"
    "eudev"

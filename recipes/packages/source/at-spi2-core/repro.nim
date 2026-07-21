import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package atSpi2CoreSource:
  versions:
    "2.54.1":
      sourceRevision = "2.54.1"
      sourceUrl = "https://download.gnome.org/sources/at-spi2-core/2.54/at-spi2-core-2.54.1.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/at-spi2-core"

  fetch:
    url: "https://download.gnome.org/sources/at-spi2-core/2.54/at-spi2-core-2.54.1.tar.xz"
    sha256: "f0729e5c8765feb1969bb6c1fba18afa2582126b0359aa75a173fda1acf93c4c"
    extractStrip: 1

  nativeBuildDeps:
    "meson >=1.0"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    "glib2 >=2.70"
    "dbus >=1.14"
    "libxml2 >=2.10"

  config:
    discard

  library libAtspi:
    discard

  library libAtk:
    discard

  library libAtkBridge:
    discard

  build:
    setCurrentOwningPackageOverride("atSpi2CoreSource")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[
        "docs=false",
        "introspection=disabled",
        "x11=disabled",
        "use_systemd=false",
        "gtk2_atk_adaptor=false",
      ])
      discard pkg.library("libAtspi")
      discard pkg.library("libAtk")
      discard pkg.library("libAtkBridge")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    "glib2 >=2.70"
    "dbus >=1.14"
    "libxml2 >=2.10"

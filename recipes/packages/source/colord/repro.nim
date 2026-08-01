import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package colordSource:
  versions:
    "1.4.6":
      sourceRevision = "1.4.6"
      sourceUrl = "https://www.freedesktop.org/software/colord/releases/colord-1.4.6.tar.xz"
      sourceRepository = "https://github.com/hughsie/colord"
  fetch:
    url: "https://www.freedesktop.org/software/colord/releases/colord-1.4.6.tar.xz"
    sha256: "7407631a27bfe5d1b672e7ae42777001c105d860b7b7392283c8c6300de88e6f"
    extractStrip: 1
  nativeBuildDeps:
    "meson >=0.56"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"
    "gettext"
  buildDeps:
    "glib2"
    "lcms2"
    "sqlite"
    "gusb"
    "libgudev"
    "eudev"
  config:
    discard
  library libcolord:
    discard
  build:
    setCurrentOwningPackageOverride("colordSource")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[
        "daemon=false",
        "session_example=false",
        "bash_completion=false",
        "udev_rules=false",
        "systemd=false",
        "libcolordcompat=false",
        "argyllcms_sensor=false",
        "sane=false",
        "introspection=false",
        "vapi=false",
        "print_profiles=false",
        "tests=false",
        "installed_tests=false",
        "man=false",
        "docs=false",
      ])
      discard pkg.library("libcolord")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "glib2"
    "lcms2"
    "sqlite"
    "gusb"
    "libgudev"
    "eudev"

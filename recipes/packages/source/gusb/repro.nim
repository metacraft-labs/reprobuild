import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package gusbSource:
  versions:
    "0.4.9":
      sourceRevision = "0.4.9"
      sourceUrl = "https://github.com/hughsie/libgusb/archive/refs/tags/0.4.9.tar.gz"
      sourceRepository = "https://github.com/hughsie/libgusb"
  fetch:
    url: "https://github.com/hughsie/libgusb/archive/refs/tags/0.4.9.tar.gz"
    sha256: "aa1242a308183d4ca6c2e8c9e3f2e345370b94308ef2d4b6e9c10d5ff6d7763e"
    extractStrip: 1
  nativeBuildDeps:
    "meson >=0.56"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"
  buildDeps:
    "glib2"
    "libusb"
    "json-glib"
  config:
    discard
  library libgusb:
    discard
  build:
    setCurrentOwningPackageOverride("gusbSource")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[
        "tests=false",
        "vapi=false",
        "docs=false",
        "introspection=false",
        "umockdev=disabled",
        "usb_ids=/usr/share/hwdata/usb.ids",
      ])
      discard pkg.library("libgusb")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "glib2"
    "libusb"
    "json-glib"

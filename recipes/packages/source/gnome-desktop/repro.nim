import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package gnomeDesktopSource:
  versions:
    "44.5":
      sourceRevision = "44.5"
      sourceUrl = "https://download.gnome.org/sources/gnome-desktop/44/gnome-desktop-44.5.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/gnome-desktop"

  fetch:
    url: "https://download.gnome.org/sources/gnome-desktop/44/gnome-desktop-44.5.tar.xz"
    sha256: "20e0995a6e3a03e8c1026c5a27bc3f45e69ffcc392ad743dcab6107a541d232f"
    extractStrip: 1

  nativeBuildDeps:
    "meson >=0.56.2"
    "ninja >=1.10"
    "gcc"
    "pkg-config"
    "gettext"

  buildDeps:
    "glib2 >=2.53"
    "gdk-pixbuf >=2.36.5"
    "gtk4 >=4.4"
    "gsettings-desktop-schemas >=3.27"
    "fontconfig"
    "xkeyboard-config"
    "iso-codes"
    "libseccomp"

  config:
    discard

  library libGnomeDesktop4:
    discard

  build:
    setCurrentOwningPackageOverride("gnomeDesktopSource")
    try:
      let pkg = meson_package(
        srcDir = "./src",
        srcPatches = @[
          "sed -i \"s/libgnome_rr_gir = ''/libgnome_rr_gir = []/\" src/libgnome-desktop/gnome-rr/meson.build",
        ],
        configureOptions = @[
          "libdir=lib",
          "desktop_docs=false",
          "debug_tools=false",
          "introspection=false",
          "udev=disabled",
          "systemd=disabled",
          "gtk_doc=false",
          "installed_tests=false",
          "build_gtk4=true",
          "legacy_library=false",
        ])
      discard pkg.library("libGnomeDesktop4")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard

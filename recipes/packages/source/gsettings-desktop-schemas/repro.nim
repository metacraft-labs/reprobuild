import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package gsettingsDesktopSchemasSource:
  versions:
    "47.1":
      sourceRevision = "47.1"
      sourceUrl = "https://download.gnome.org/sources/gsettings-desktop-schemas/47/gsettings-desktop-schemas-47.1.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/gsettings-desktop-schemas"

  fetch:
    url: "https://download.gnome.org/sources/gsettings-desktop-schemas/47/gsettings-desktop-schemas-47.1.tar.xz"
    sha256: "a60204d9c9c0a1b264d6d0d134a38340ba5fc6076a34b84da945d8bfcc7a2815"
    extractStrip: 1

  nativeBuildDeps:
    "meson >=1.0"
    "ninja >=1.10"
    "pkg-config"
    "glib2 >=2.70"
    "gobject-introspection"

  buildDeps:
    "glib2 >=2.70"
    "glib2-introspection"

  config:
    discard

  files schemaFiles:
    discard

  build:
    setCurrentOwningPackageOverride("gsettingsDesktopSchemasSource")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[
        "introspection=true",
      ], extraEnv = @[
        ("GI_GIR_PATH",
          "/opt/repro/reprobuild/recipes/packages/source/glib2-introspection/.repro/output/install/usr/share/gir-1.0"),
        ("XDG_DATA_DIRS",
          "/opt/repro/reprobuild/recipes/packages/source/glib2-introspection/.repro/output/install/usr/share"),
      ])
      discard pkg.files("schemaFiles")
      pkg.installTreeMirror()
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    "glib2 >=2.70"

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package gjsSource:
  versions:
    "1.82.3":
      sourceRevision = "1.82.3"
      sourceUrl = "https://download.gnome.org/sources/gjs/1.82/gjs-1.82.3.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/gjs"
  fetch:
    url: "https://download.gnome.org/sources/gjs/1.82/gjs-1.82.3.tar.xz"
    sha256: "63e84b9c82a60d166c8704322f8907945e25d9bbd0b80485468d3126505c027d"
    extractStrip: 1
  nativeBuildDeps:
    "meson >=0.64"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"
    "glib2-introspection >=2.82"
  buildDeps:
    "glib2 >=2.80"
    "libffi"
    "gobject-introspection >=1.66"
    "cairo"
    "mozjs128 >=128"
  config:
    discard
  library libGjs:
    discard
  executable gjs:
    discard
  build:
    setCurrentOwningPackageOverride("gjsSource")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[
        "readline=disabled",
        "profiler=disabled",
        "installed_tests=false",
        "dtrace=false",
        "systemtap=false",
      ], extraEnv = @[
        ("CPATH", "/opt/repro/reprobuild/recipes/packages/source/glib2/.repro/output/install/usr/include/glib-2.0:/opt/repro/reprobuild/recipes/packages/source/glib2/.repro/output/install/usr/lib/glib-2.0/include"),
        ("PYTHONPATH", "/opt/repro/reprobuild/recipes/packages/source/gobject-introspection/.repro/output/install/usr/lib/gobject-introspection"),
        ("GI_GIR_PATH", "/opt/repro/reprobuild/recipes/packages/source/glib2-introspection/.repro/output/install/usr/share/gir-1.0"),
        ("GI_TYPELIB_PATH", "/opt/repro/reprobuild/recipes/packages/source/glib2-introspection/.repro/output/install/usr/lib/girepository-1.0"),
        ("LD_LIBRARY_PATH", "/opt/repro/reprobuild/recipes/packages/source/glib2/.repro/output/install/usr/lib:/opt/repro/reprobuild/recipes/packages/source/gobject-introspection/.repro/output/install/usr/lib:/opt/repro/reprobuild/recipes/packages/source/libffi/.repro/output/install/usr/lib:/opt/repro/reprobuild/recipes/packages/source/pcre2/.repro/output/install/usr/lib"),
      ])
      discard pkg.library("libGjs")
      discard pkg.executable("gjs")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "glib2 >=2.80"
    "libffi"
    "gobject-introspection >=1.66"
    "cairo"
    "mozjs128 >=128"

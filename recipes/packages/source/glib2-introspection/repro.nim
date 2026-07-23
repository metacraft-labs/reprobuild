import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package glib2IntrospectionSource:
  versions:
    "2.82.5":
      sourceRevision = "2.82.5"
      sourceUrl = "https://download.gnome.org/sources/glib/2.82/glib-2.82.5.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/glib"
  fetch:
    url: "https://download.gnome.org/sources/glib/2.82/glib-2.82.5.tar.xz"
    sha256: "05c2031f9bdf6b5aba7a06ca84f0b4aced28b19bf1b50c6ab25cc675277cbc3f"
    extractStrip: 1
  nativeBuildDeps:
    "meson >=0.79"
    "ninja >=1.10"
    "gcc >=11"
    "python3"
    "pkg-config"
    "gobject-introspection >=1.66"
  buildDeps:
    "glib2 >=2.82"
    "pcre2 >=10.34"
    "libffi"
    "zlib"
  config:
    discard
  executable gio:
    discard
  executable glib2Introspection:
    name: "glib2-introspection"
    discard
  build:
    setCurrentOwningPackageOverride("glib2IntrospectionSource")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[
        "tests=false",
        "documentation=false",
        "man-pages=disabled",
        "introspection=enabled",
        "sysprof=disabled",
        "nls=disabled",
        "xattr=false",
        "libdir=lib",
      ], extraEnv = @[
        ("PYTHONPATH", "/opt/repro/reprobuild/recipes/packages/source/gobject-introspection/.repro/output/install/usr/lib/gobject-introspection"),
        ("GI_GIR_PATH", "/opt/repro/reprobuild/recipes/packages/source/gobject-introspection/build/gir"),
        ("LD_LIBRARY_PATH", "/opt/repro/reprobuild/recipes/packages/source/glib2/.repro/output/install/usr/lib:/opt/repro/reprobuild/recipes/packages/source/gobject-introspection/.repro/output/install/usr/lib:/opt/repro/reprobuild/recipes/packages/source/libffi/.repro/output/install/usr/lib:/opt/repro/reprobuild/recipes/packages/source/pcre2/.repro/output/install/usr/lib"),
      ])
      discard pkg.executable("gio")
      discard pkg.executableAlias("glib2-introspection", sourceName = "gio")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "glib2 >=2.82"
    "gobject-introspection >=1.66"

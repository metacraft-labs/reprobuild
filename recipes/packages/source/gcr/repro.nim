import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package gcrSource:
  versions:
    "4.3.0":
      sourceRevision = "4.3.0"
      sourceUrl = "https://download.gnome.org/sources/gcr/4.3/gcr-4.3.0.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/gcr"
  fetch:
    url: "https://download.gnome.org/sources/gcr/4.3/gcr-4.3.0.tar.xz"
    sha256: "c3ee8728e4364b0397f435fa20f92f901ab139d2b264f4e059d67b3c0f43cd36"
    extractStrip: 1
  nativeBuildDeps:
    "meson >=0.59"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"
    "gobject-introspection"
  buildDeps:
    "glib2 >=2.68"
    "p11-kit >=0.19"
    "libgcrypt >=1.8"
    "libgpg-error >=1.46"
    "glib2-introspection"
  config:
    discard
  library libGcr4:
    discard
  library libGck2:
    discard
  build:
    setCurrentOwningPackageOverride("gcrSource")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[
        "introspection=true",
        "vapi=false",
        "gtk4=false",
        "gtk_doc=false",
        "gpg_path=/usr/bin/gpg",
        "crypto=libgcrypt",
        "ssh_agent=false",
        "systemd=disabled",
      ], extraEnv = @[
        ("CPATH", "/opt/repro/reprobuild/recipes/packages/source/glib2/.repro/output/install/usr/include/glib-2.0:/opt/repro/reprobuild/recipes/packages/source/glib2/.repro/output/install/usr/lib/glib-2.0/include:/opt/repro/reprobuild/recipes/packages/source/p11-kit/.repro/output/install/usr/include/p11-kit-1:/opt/repro/reprobuild/recipes/packages/source/libgcrypt/.repro/output/install/usr/include:/opt/repro/reprobuild/recipes/packages/source/libgpg-error/.repro/output/install/usr/include"),
        ("GI_GIR_PATH", "/opt/repro/reprobuild/recipes/packages/source/glib2-introspection/.repro/output/install/usr/share/gir-1.0"),
        ("XDG_DATA_DIRS", "/opt/repro/reprobuild/recipes/packages/source/glib2-introspection/.repro/output/install/usr/share"),
      ])
      discard pkg.library("libGcr4")
      discard pkg.library("libGck2")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "glib2 >=2.68"
    "p11-kit >=0.19"
    "libgcrypt >=1.8"
    "libgpg-error >=1.46"

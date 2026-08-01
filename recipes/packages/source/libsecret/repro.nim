import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libsecretSource:
  versions:
    "0.21.6":
      sourceRevision = "0.21.6"
      sourceUrl = "https://download.gnome.org/sources/libsecret/0.21/libsecret-0.21.6.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/libsecret"

  fetch:
    url: "https://download.gnome.org/sources/libsecret/0.21/libsecret-0.21.6.tar.xz"
    sha256: "747b8c175be108c880d3adfb9c3537ea66e520e4ad2dccf5dce58003aeeca090"
    extractStrip: 1

  nativeBuildDeps:
    "meson >=1.0"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"

  buildDeps:
    "glib2 >=2.70"
    "libgcrypt >=1.10"

  config:
    discard

  library libSecret:
    discard

  build:
    setCurrentOwningPackageOverride("libsecretSource")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[
        "manpage=false",
        "crypto=libgcrypt",
        "vapi=false",
        "gtk_doc=false",
        "introspection=false",
        "bash_completion=disabled",
        "tpm2=false",
        "pam=false",
      ], extraEnv = @[
        ("CPATH", "/opt/repro/reprobuild/recipes/packages/source/glib2/.repro/output/install/usr/include/glib-2.0:/opt/repro/reprobuild/recipes/packages/source/glib2/.repro/output/install/usr/lib/glib-2.0/include:/opt/repro/reprobuild/recipes/packages/source/libgcrypt/.repro/output/install/usr/include:/opt/repro/reprobuild/recipes/packages/source/libgpg-error/.repro/output/install/usr/include"),
      ])
      discard pkg.library("libSecret")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    "glib2 >=2.70"
    "libgcrypt >=1.10"

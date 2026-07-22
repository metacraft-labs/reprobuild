import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libsoup3Source:
  versions:
    "3.6.5":
      sourceRevision = "3.6.5"
      sourceUrl = "https://download.gnome.org/sources/libsoup/3.6/libsoup-3.6.5.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/libsoup"
  fetch:
    url: "https://download.gnome.org/sources/libsoup/3.6/libsoup-3.6.5.tar.xz"
    sha256: "6891765aac3e949017945c3eaebd8cc8216df772456dc9f460976fbdb7ada234"
    extractStrip: 1
  nativeBuildDeps:
    "meson >=1.0"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"
  buildDeps:
    "glib2 >=2.70"
    "nghttp2 >=1.50"
    "sqlite >=3.40"
    "libpsl >=0.20"
    "zlib"
  config:
    discard
  library libSoup3:
    discard
  build:
    setCurrentOwningPackageOverride("libsoup3Source")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[
        "gssapi=disabled", "ntlm=disabled", "brotli=disabled",
        "tls_check=false", "introspection=disabled", "vapi=disabled",
        "docs=disabled", "tests=false", "autobahn=disabled",
        "installed_tests=false", "sysprof=disabled", "fuzzing=disabled",
        "pkcs11_tests=disabled",
      ], extraEnv = @[
        ("CPATH", "/opt/repro/reprobuild/recipes/packages/source/glib2/.repro/output/install/usr/include/glib-2.0:/opt/repro/reprobuild/recipes/packages/source/glib2/.repro/output/install/usr/lib/glib-2.0/include:/opt/repro/reprobuild/recipes/packages/source/nghttp2/.repro/output/install/usr/include:/opt/repro/reprobuild/recipes/packages/source/sqlite/.repro/output/install/usr/include:/opt/repro/reprobuild/recipes/packages/source/libpsl/.repro/output/install/usr/include:/opt/repro/reprobuild/recipes/packages/source/zlib/.repro/output/install/usr/include"),
      ])
      discard pkg.library("libSoup3")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "glib2 >=2.70"
    "nghttp2 >=1.50"
    "sqlite >=3.40"
    "libpsl >=0.20"
    "zlib"

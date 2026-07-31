import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libxdmcpSource:
  versions:
    "1.1.5":
      sourceRevision = "libXdmcp-1.1.5"
      sourceUrl = "https://www.x.org/releases/individual/lib/libXdmcp-1.1.5.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libxdmcp"
  fetch:
    url: "https://www.x.org/releases/individual/lib/libXdmcp-1.1.5.tar.xz"
    sha256: "d8a5222828c3adab70adf69a5583f1d32eb5ece04304f7f8392b6a353aa2228c"
    extractStrip: 1
  nativeBuildDeps:
    "make"
    "gcc >=11"
    "pkg-config"
  buildDeps:
    "xorgproto"
  config:
    discard
  library libXdmcp:
    discard
  build:
    setCurrentOwningPackageOverride("libxdmcpSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared",
      ])
      discard pkg.library("libXdmcp")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    discard

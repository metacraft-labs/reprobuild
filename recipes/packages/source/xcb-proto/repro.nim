import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package xcbProtoSource:
  versions:
    "1.17.0":
      sourceRevision = "xcb-proto-1.17.0"
      sourceUrl = "https://www.x.org/releases/individual/proto/xcb-proto-1.17.0.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/proto/xcbproto"
  fetch:
    url: "https://www.x.org/releases/individual/proto/xcb-proto-1.17.0.tar.xz"
    sha256: "2c1bacd2110f4799f74de6ebb714b94cf6f80fb112316b1219480fd22562148c"
    extractStrip: 1
  nativeBuildDeps:
    "make"
    "gcc >=11"
    "pkg-config"
    "python3"
  config:
    discard
  build:
    setCurrentOwningPackageOverride("xcbProtoSource")
    try:
      let pkg = autotools_package(srcDir = "./src")
      pkg.installTreeMirror()
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    discard

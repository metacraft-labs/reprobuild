import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libfontencSource:
  versions:
    "1.1.8":
      sourceRevision = "libfontenc-1.1.8"
      sourceUrl = "https://www.x.org/releases/individual/lib/libfontenc-1.1.8.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/lib/libfontenc"
  fetch:
    url: "https://www.x.org/releases/individual/lib/libfontenc-1.1.8.tar.xz"
    sha256: "7b02c3d405236e0d86806b1de9d6868fe60c313628b38350b032914aa4fd14c6"
    extractStrip: 1
  nativeBuildDeps:
    "make"
    "gcc >=11"
    "pkg-config"
  buildDeps:
    "xorgproto"
    "zlib"
  config:
    discard
  library libfontenc:
    discard
  build:
    setCurrentOwningPackageOverride("libfontencSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared",
      ])
      discard pkg.library("libfontenc")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "zlib"

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result
import repro_dsl_stdlib/packages/rustc
import repro_dsl_stdlib/packages/cargo
import repro_dsl_stdlib/packages/python3
import repro_dsl_stdlib/packages/m4
import repro_dsl_stdlib/packages/perl
import repro_dsl_stdlib/packages/llvm_objdump
import repro_dsl_stdlib/packages/cbindgen

package mozjs128Source:
  versions:
    "128.5.0":
      sourceRevision = "FIREFOX_128_5_0esr_RELEASE"
      sourceUrl = "https://archive.mozilla.org/pub/firefox/releases/128.5.0esr/source/firefox-128.5.0esr.source.tar.xz"
      sourceRepository = "https://hg.mozilla.org/releases/mozilla-esr128"
  fetch:
    url: "https://archive.mozilla.org/pub/firefox/releases/128.5.0esr/source/firefox-128.5.0esr.source.tar.xz"
    sha256: "0bd18968314afdcc341edd2a9178e305c9d454560a42193154a0f994047fecb8"
    extractStrip: 1
  nativeBuildDeps:
    "gcc >=11"
    "make >=4.0"
    "pkg-config"
    "python3 >=3.10"
    "rustc >=1.75"
    "cargo >=1.75"
    "m4"
    "perl"
    "llvm-objdump"
    "cbindgen"
  buildDeps:
    "readline"
    "zlib"
  config:
    discard
  library libMozjs128:
    discard
  executable js128:
    discard
  build:
    setCurrentOwningPackageOverride("mozjs128Source")
    try:
      let pkg = autotools_package(
        srcDir = "./src/js",
        buildDir = "build",
        configureScriptName = "src/configure",
        configureOptions = @[
          "--with-intl-api",
          "--with-system-zlib",
          "--enable-optimize",
          "--enable-readline",
          "--enable-release",
          "--enable-shared-js",
          "--disable-debug",
          "--disable-debug-symbols",
          "--disable-jemalloc",
          "--enable-strip",
          "--disable-tests",
          "--disable-warnings-as-errors",
        ],
        allowSourceWrites = true,
        srcPatches = @[
          "export MOZBUILD_STATE_PATH=\"$PWD/.mozbuild\"",
          "export PYTHON=\"$(command -v python3)\"",
          "export M4=\"$(command -v m4)\"",
          "export AWK=\"$(command -v awk)\"",
          "export AS=\"$(command -v gcc)\"",
        ])
      discard pkg.library("libMozjs128")
      discard pkg.executable("js128")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "readline"
    "zlib"

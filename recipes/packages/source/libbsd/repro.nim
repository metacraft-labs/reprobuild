import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libbsdSource:
  versions:
    "0.12.2":
      sourceRevision = "0.12.2"
      sourceUrl = "https://libbsd.freedesktop.org/releases/libbsd-0.12.2.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/libbsd/libbsd"
  fetch:
    url: "https://libbsd.freedesktop.org/releases/libbsd-0.12.2.tar.xz"
    sha256: "b88cc9163d0c652aaf39a99991d974ddba1c3a9711db8f1b5838af2a14731014"
    extractStrip: 1
  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"
  buildDeps:
    "libmd"
  config:
    discard
  library libbsd:
    discard
  build:
    setCurrentOwningPackageOverride("libbsdSource")
    try:
      # Upstream emits an ld script with /usr/lib/<soname> in GROUP().
      # Keep the soname relative so consumers can link against the staged
      # source output before it is assembled into the final /usr tree.
      let patches = @[
        "sed -i 's|GROUP($(runtimelibdir)/$$soname|GROUP($$soname|' " &
          "src/src/Makefile.in",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared",
      ], srcPatches = patches)
      discard pkg.library("libbsd")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "libmd"

## Source-built musl libc used for static early-boot utilities.
##
## ReproOS needs an initramfs executable that does not depend on the
## installed root filesystem. musl provides a compact static libc and a
## compiler wrapper suitable for building that executable from source.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package muslSource:
  versions:
    "1.2.6":
      sourceRevision = "v1.2.6"
      sourceUrl = "https://musl.libc.org/releases/musl-1.2.6.tar.gz"
      sourceRepository = "https://git.musl-libc.org/cgit/musl"

  fetch:
    url: "https://musl.libc.org/releases/musl-1.2.6.tar.gz"
    sha256: "d585fd3b613c66151fc3249e8ed44f77020cb5e6c1e635a616d3f9f82460512a"
    extractStrip: 1

  nativeBuildDeps:
    "gcc >=11"
    "make >=4"

  config:
    discard

  executable musl:
    discard

  build:
    setCurrentOwningPackageOverride("muslSource")
    try:
      let opts = @[
        "--disable-shared",
        "--enable-wrapper=gcc",
        "--syslibdir=/usr/lib",
      ]
      let patches = @[
        "printf '\n.PHONY: repro_install\nrepro_install:\n\t$(MAKE) install\n\tsed -i s@/usr/@/opt/repro/reprobuild/recipes/packages/source/musl/.repro/output/install/usr/@g $(DESTDIR)/usr/lib/musl-gcc.specs\n\tsed -i s@/usr/lib/musl-gcc.specs@/opt/repro/reprobuild/recipes/packages/source/musl/.repro/output/install/usr/lib/musl-gcc.specs@ $(DESTDIR)/usr/bin/musl-gcc\n\tln -sf musl-gcc $(DESTDIR)/usr/bin/musl\n' >> ./src/Makefile",
      ]
      let pkg = autotools_package(
        srcDir = "./src",
        configureOptions = opts,
        installTarget = "repro_install",
        srcPatches = patches,
      )
      discard pkg.executable("musl")
      pkg.installTreeMirror()
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard

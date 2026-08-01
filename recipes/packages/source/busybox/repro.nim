## Source-built static BusyBox for the ReproOS initramfs.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package busyboxSource:
  versions:
    "1.36.1":
      sourceRevision = "1_36_1"
      sourceUrl = "https://busybox.net/downloads/busybox-1.36.1.tar.bz2"
      sourceRepository = "https://git.busybox.net/busybox"

  fetch:
    url: "https://busybox.net/downloads/busybox-1.36.1.tar.bz2"
    sha256: "b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314"
    extractStrip: 1

  nativeBuildDeps:
    "gcc >=11"
    "make >=4"
    "musl"

  config:
    discard

  executable busybox:
    discard

  build:
    setCurrentOwningPackageOverride("busyboxSource")
    try:
      let opts = @[
        "CC=musl-gcc",
        "KCONFIG_NOTIMESTAMP=1",
      ]
      let patches = @[
        "make -C ./src defconfig",
        "sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/; s/CONFIG_TC=y/# CONFIG_TC is not set/; s/CONFIG_FEATURE_TC_INGRESS=y/# CONFIG_FEATURE_TC_INGRESS is not set/; s/CONFIG_SELINUX=y/# CONFIG_SELINUX is not set/' ./src/.config",
        "make -C ./src oldconfig </dev/null",
        "printf '\n.PHONY: repro_install\nrepro_install:\n\tmkdir -p $(DESTDIR)/usr/bin\n\tcp busybox $(DESTDIR)/usr/bin/busybox\n' >> ./src/Makefile",
      ]
      let pkg = autotools_package(
        srcDir = "./src",
        configureOptions = opts,
        skipConfigure = true,
        installTarget = "repro_install",
        srcPatches = patches,
      )
      discard pkg.executable("busybox")
      pkg.installTreeMirror()
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard

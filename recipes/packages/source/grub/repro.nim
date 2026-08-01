## GNU GRUB built for the x86_64 UEFI platform used by ReproOS.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package grubSource:
  versions:
    "2.12":
      sourceRevision = "grub-2.12"
      sourceUrl = "https://ftp.gnu.org/gnu/grub/grub-2.12.tar.xz"
      sourceRepository = "https://git.savannah.gnu.org/git/grub.git"

  fetch:
    url: "https://ftp.gnu.org/gnu/grub/grub-2.12.tar.xz"
    sha256: "f3c97391f7c4eaa677a78e090c7e97e6dc47b16f655f04683ebd37bef7fe0faa"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "make"
    "gcc >=11"
    "bison"
    "flex"
    "gettext"
    "pkg-config"
    "python3"

  buildDeps:
    "freetype >=2.10"

  config:
    discard

  build:
    setCurrentOwningPackageOverride("grubSource")
    try:
      let opts = @[
        "--target=x86_64",
        "--with-platform=efi",
        "--disable-werror",
        "--disable-nls",
        "--disable-device-mapper",
        "CFLAGS=-fno-PIE",
        "LDFLAGS=-no-pie",
      ]
      let patches = @[
        "sed -i 's/${TARGET_LDFLAGS} -nostdlib/${TARGET_LDFLAGS} -Wl,--no-dynamic-linker -nostdlib/' ./src/configure",
        "touch ./src/grub-core/extra_deps.lst",
      ]
      let pkg = autotools_package(
        srcDir = "./src",
        configureOptions = opts,
        srcPatches = patches,
      )
      pkg.installTreeMirror()
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    "freetype >=2.10"

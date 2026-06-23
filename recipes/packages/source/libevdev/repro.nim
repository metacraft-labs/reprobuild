## Source-from-tarball libevdev recipe — closes M9.R.26 Gap 2.
##
## Replaces the prior ``libs/repro_dsl_stdlib/.../packages/libevdev.nim``
## nix-store provisioning stub. libevdev was previously resolved
## through the nix-store closure mirror in ``stage-de-rootfs.sh`` (the
## ``libevdev-<v>`` derivation pulled in transitively by libinput).
## M9.R.26 promotes it to a first-class from-source recipe so the
## DE-staging surface is genuinely "no nix-store reliance" for runtime
## input-device deps.
##
## ## Why libevdev matters for the v1 desktop story
##
## libevdev is the kernel-evdev abstraction layer libinput links
## against to consume per-device input events with a stable, well-
## typed C API on top of the raw evdev ioctls. Every modern Wayland
## compositor (sway / mutter / kwin) consumes libinput, which consumes
## libevdev; the live ISO needs the .so on the runtime path or the
## compositors fail to initialise their seat/input layers.
##
## ## sha256 strategy
##
## We vendor the upstream 1.13.4 .tar.xz at
## ``recipes/packages/source/libevdev/vendor/libevdev-1.13.4.tar.xz``
## and reference it via the freedesktop.org URL. The live ``fetch:``
## block records the canonical URL; the convention layer's argv
## carries it verbatim so the engine's content-addressed cache
## fingerprint stays stable across rebuilds.
##
## sha256 = f00ab8d42ad8b905296fab67e13b871f1a424839331516642100f82ad88127cd
##  (computed locally over the vendored ``libevdev-1.13.4.tar.xz``,
##  464,556 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Version choice — 1.13.4 (current upstream stable)
##
## libevdev releases are cut at freedesktop.org under tags of the
## form ``libevdev-<X>.<Y>.<Z>``. 1.13.4 is the current stable as of
## mid-2026 and the ABI has been stable since the 1.0 cut — anything
## ``>=1.10`` covers libinput / kwin / mutter consumption.
##
## ## Build shape
##
## libevdev's upstream build is autoconf-generated ``./configure`` +
## ``make``. The c_cpp_autotools convention (M9.K) lowers the
## ``fetch:`` + ``configureFlags:`` blocks into the fetch + configure
## + make + install action chain.
##
## ## Library artifact
##
## libevdev's autotools build emits a single shared library
## (``libevdev.so``) bundling the evdev event-loop helpers + the
## device-property accessors. The on-disk SONAME is
## ``libevdev.so.2``. We register the artifact under the package-level
## identifier ``libEvdev``.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package libevdevSource:
  ## From-source libevdev — closes M9.R.26 Gap 2. Tier-2b
  ## c_cpp_autotools convention consumer. Single library artifact
  ## recipe.

  versions:
    "1.13.4":
      sourceRevision = "libevdev-1.13.4"
      sourceUrl = "https://www.freedesktop.org/software/libevdev/libevdev-1.13.4.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/libevdev/libevdev"

  fetch:
    url: "https://www.freedesktop.org/software/libevdev/libevdev-1.13.4.tar.xz"
    sha256: "f00ab8d42ad8b905296fab67e13b871f1a424839331516642100f82ad88127cd"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    ## libevdev's autogen step runs Python to parse the kernel's
    ## ``input-event-codes.h`` into the libevdev event-name tables.
    "python3"

  buildDeps:
    ## No external runtime deps — libevdev is a thin wrapper over the
    ## kernel evdev API and links against libc only.
    discard

  config:
    discard
  library libEvdev:
    discard

  build:
    setCurrentOwningPackageOverride("libevdevSource")
    try:
      let opts = @[
        "--disable-static",
        "--enable-shared",
        # Skip the test suite (depends on libcheck which is not in
        # our from-source closure and not needed at runtime).
        "--disable-tests",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libEvdev")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard

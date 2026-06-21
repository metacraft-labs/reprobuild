## Source-from-tarball mesa recipe — drives M9.R.15m.1 (the MAJOR
## OpenGL/EGL/GBM gap blocking the kwin + mutter compositors and the
## qt6-base OpenGL component). Mesa is the canonical open-source 3D
## graphics stack: it provides libGL.so / libEGL.so / libGLESv2.so /
## libgbm.so — the four ABIs Wayland compositors + Qt's OpenGL backend
## hard-require from the host.
##
## ## Why mesa matters for the v1 desktop story
##
## Two load-bearing consumers in the v1 desktop story require mesa:
##
##   * KDE Plasma's ``kwin`` Wayland compositor links against libEGL +
##     libgbm to drive its GPU-backed scene graph. Without mesa, kwin's
##     CMake configure fails the ``find_package(EGL REQUIRED)`` probe.
##   * GNOME's ``mutter`` Wayland compositor (gnome-shell's display
##     server) links against libEGL + libGLESv2 + libgbm for the same
##     reasons.
##
## Mesa is a HEAVY meson-driven C/C++ stack with over a hundred build
## options. The v1 recipe targets the MINIMAL feature set sufficient to
## satisfy compositor link requirements: software rasterizer only
## (``swrast``), Wayland platform only, no Vulkan, no X11. Hardware
## acceleration is OUT OF SCOPE for v1 — the goal is to publish the
## libGL / libEGL / libGLESv2 / libgbm ABIs so downstream KF6 / Qt6 /
## GNOME consumers can link.
##
## ## sha256 strategy
##
## We vendor the upstream 24.2.8 .tar.xz at
## ``recipes/packages/source/mesa/vendor/mesa-24.2.8.tar.xz`` and
## reference it via the canonical upstream URL recorded both in the
## ``versions:`` block AND the live ``fetch:`` block (the vendored copy
## is the on-host snapshot the canonical URL resolved to at
## recipe-authoring time — content-addressed via sha256). Matches the
## post-M9.R.14d.2 convention that EVERY ``fetch:`` URL points at the
## upstream URL, never at a host-absolute ``file:///`` path.
##
## ## Version choice — 23.3.6 (last stable before the 24.x
## ``loader_wayland_helper.c`` regression)
##
## Mesa 24.2.8 and 24.3.4 ship a known compile-time bug in
## ``src/loader/loader_wayland_helper.c``: the function
## ``loader_wayland_dispatch`` (added in 24.x for the
## ``wl_display_dispatch_queue_timeout`` integration) calls
## ``clock_gettime(CLOCK_MONOTONIC, ...)`` and
## ``timespec_sub_saturate(...)`` UNCONDITIONALLY, but the
## ``<time.h>`` and ``util/timespec.h`` headers are only included
## inside the ``#ifndef HAVE_WL_DISPATCH_QUEUE_TIMEOUT`` block. Since
## our wayland 1.25 supplies the symbol, the guard is true, the
## headers are skipped, and compilation fails with:
##   error: implicit declaration of function 'clock_gettime'
##   error: 'CLOCK_MONOTONIC' undeclared
##
## Mesa 23.3.6 PRE-DATES the ``loader_wayland_helper.c`` file
## entirely (the file was added in mesa 24.0). Switching to the
## 23.3.x line avoids the broken file without compromising on the
## OpenGL/EGL/GBM ABI surface — KF6 / Qt6 / GNOME consumers do not
## pin a tighter mesa version, and 23.3 still ships every public
## symbol we need (libGL, libEGL, libGLESv2, libgbm).
##
## Once the v1 patching infrastructure lands (M9.M+), we can re-bump
## to a 24.x stable with the one-line ``#include`` fix applied as a
## proper patch series.
##
## sha256 = cd3d6c60121dea73abbae99d399dc2facaecde1a8c6bd647e6d85410ff4b577b
##  (computed locally over the vendored ``mesa-23.3.6.tar.xz``,
##  19,455,492 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
##
## ## Build shape
##
## Mesa uses meson (the c_cpp_meson convention) — same as the sibling
## wayland / libdrm / cairo / pango meson recipes.
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to the
## minimal modern-desktop baseline that ships ONLY the swrast software
## rasterizer driver + the Wayland platform integration:
##
##   * ``vulkan-drivers=``      — disable Vulkan entirely (no GPU
##                                 vendor backends; the swrast software
##                                 rasterizer satisfies compositor
##                                 startup probes without GPU).
##   * ``gallium-drivers=swrast`` — software rasterizer ONLY. Mesa
##                                 23.3.x still ships ``swrast`` as a
##                                 native choice (the 24.x rename to
##                                 ``softpipe,llvmpipe`` happened
##                                 post-24.0). ``swrast`` on 23.3
##                                 builds the pure-C softpipe path
##                                 when LLVM is disabled. No hardware
##                                 drivers (i915, iris, radeon,
##                                 nouveau, etc.) — these would pull
##                                 libpciaccess + LLVM + kernel-DRM
##                                 deps far beyond v1 scope. swrast is
##                                 enough for KF6 / GNOME / Qt6 to
##                                 link + run their software-fallback
##                                 paths.
##   * ``platforms=wayland``     — Wayland platform support ONLY. No
##                                 X11 (xcb/xlib) — the v1 desktop is
##                                 Wayland-native.
##   * ``glx=disabled``          — disable GLX (X11 OpenGL extension);
##                                 v1 has no X11 server.
##   * ``gles1=disabled``        — disable GLES1 (legacy mobile API; no
##                                 v1 consumers).
##   * ``egl=enabled``           — REQUIRED for kwin + mutter + Qt6.
##   * ``gles2=enabled``         — REQUIRED for mutter + Qt6.
##   * ``gbm=enabled``           — REQUIRED for kwin + mutter (GBM is
##                                 the buffer-management ABI Wayland
##                                 compositors use for direct scanout).
##   * ``gallium-vdpau=disabled`` — disable VDPAU video acceleration
##                                 backend (no v1 consumer).
##   * ``gallium-va=disabled``   — disable VA-API video acceleration
##                                 backend (no v1 consumer).
##   * ``gallium-xa=disabled``   — disable XA state tracker (X11
##                                 acceleration; v1 has no X11 server).
##   * ``llvm=disabled``         — disable LLVM dependency (swrast can
##                                 use it for JIT but works without;
##                                 v1 avoids the multi-GB LLVM deps).
##   * ``shared-llvm=disabled``  — paired with ``llvm=disabled``.
##   * ``valgrind=disabled``     — no valgrind integration in v1 builds.
##   * ``libunwind=disabled``    — no libunwind integration in v1
##                                 (skips the libunwind probe).
##   * ``android-libbacktrace=disabled`` — no Android stack-trace lib.
##   * ``tools=`` (empty)         — skip the optional Mesa tools.
##   * ``microsoft-clc=disabled`` — disable the MS OpenCL compiler.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package mesaSource:
  ## From-source mesa — drives M9.R.15m.1: the OpenGL / EGL / GBM gap
  ## blocking the kwin + mutter Wayland compositors. v1 builds the
  ## software-rasterizer-only configuration sufficient to satisfy
  ## kwin/mutter/Qt6 link requirements.
  ##
  ## Tier-2b c_cpp_meson convention consumer. Four library artifact
  ## recipe (libGL + libEGL + libGLESv2 + libgbm).

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## archive.mesa3d.org release tarball URL; ``sourceRepository``
    ## points at the upstream gitlab project that hosts the mesa
    ## source tree.
    "23.3.6":
      sourceRevision = "mesa-23.3.6"
      sourceUrl = "https://archive.mesa3d.org/mesa-23.3.6.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/mesa/mesa"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## Upstream URL pinned per the post-M9.R.14d.2 convention; the
    ## convention layer's argv carries this URL verbatim so the
    ## engine's content-addressed cache fingerprint stays stable
    ## across rebuilds.
    ##
    ## sha256 was computed over the vendored 19,455,492-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://archive.mesa3d.org/mesa-23.3.6.tar.xz"
    sha256: "cd3d6c60121dea73abbae99d399dc2facaecde1a8c6bd647e6d85410ff4b577b"
    extractStrip: 1

  nativeBuildDeps:
    ## meson is the build-system driver.
    "meson >=1.3"
    ## ninja is meson's default backend.
    "ninja >=1.10"
    ## pkg-config is used by meson to discover dependencies.
    "pkg-config"
    ## python3-with-modules drives mesa's many GLSL/GL spec code
    ## generators (over a dozen .py scripts in src/). Mesa hard-requires
    ## the ``mako`` template module (src/meson.build:958 errors with
    ## "Python (3.x) mako module >= 0.8.0 required to build mesa" if
    ## the bare python3 is used). We consume the
    ## python3-with-modules stub (which bundles setuptools + mako +
    ## markdown via nixpkgs' ``python3.withPackages``) to satisfy the
    ## probe.
    "python3-with-modules"
    ## bison generates the GLSL preprocessor parser
    ## (src/compiler/glsl/glcpp/glcpp-parse.y).
    "bison"
    ## flex generates the GLSL preprocessor lexer.
    "flex"
    ## gcc is the host C/C++ toolchain — mesa is C11 + C++17.
    "gcc >=11"

  buildDeps:
    ## libdrm provides the DRM ioctl wrapper consumed by mesa's GBM
    ## + DRI back-ends.
    "libdrm >=2.4"
    ## libxml2 is used by mesa's GL XML registry parser.
    "libxml2 >=2.9"
    ## zlib is consumed by mesa for shader-cache compression.
    "zlib"
    ## expat parses GLX/EGL extension XML at build time.
    "expat"
    ## wayland provides the Wayland client + server ABIs the EGL +
    ## GBM Wayland integrations link against.
    "wayland >=1.18"
    ## wayland-protocols ships the additional XML protocol files mesa
    ## uses to generate Wayland glue.
    "wayland-protocols"

  config:
    ## No prefix lifted from `mesonOptions:`; flags inlined in the `build:` block.
    discard
  library libGL:
    ## ``libGL.so`` — the desktop OpenGL ABI consumed by Qt6OpenGL
    ## + legacy GL applications. Software-rasterized via swrast in
    ## the v1 configuration.
    ## v1 records the artifact only; the per-artifact build body
    ## lands in M9.L when the convention's ninja-spawn + install-glue
    ## closes.
    discard

  library libEGL:
    ## ``libEGL.so`` — the EGL ABI consumed by kwin + mutter +
    ## Qt6OpenGL for Wayland-native GL context creation.
    discard

  library libGLESv2:
    ## ``libGLESv2.so`` — the GLES2 ABI consumed by mutter (gnome
    ## shell's GLES2 renderer).
    discard

  library libGbm:
    ## ``libgbm.so`` — the Generic Buffer Manager ABI consumed by
    ## kwin + mutter for direct scanout buffer allocation.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `meson_package(...)` constructor.
    setCurrentOwningPackageOverride("mesaSource")
    try:
      let opts = @[
        "vulkan-drivers=",
        "gallium-drivers=swrast",
        "platforms=wayland",
        "glx=disabled",
        "gles1=disabled",
        "egl=enabled",
        "gles2=enabled",
        "gbm=enabled",
        "gallium-vdpau=disabled",
        "gallium-va=disabled",
        "gallium-xa=disabled",
        "llvm=disabled",
        "shared-llvm=disabled",
        "valgrind=disabled",
        "libunwind=disabled",
        "android-libbacktrace=disabled",
        "tools=",
        "microsoft-clc=disabled",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libGL")
      discard pkg.library("libEGL")
      discard pkg.library("libGLESv2")
      discard pkg.library("libGbm")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

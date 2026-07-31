## Source-from-tarball mesa recipe — drives M9.R.15m.1 (the MAJOR
## OpenGL/EGL/GBM gap blocking the kwin + mutter compositors and the
## qt6-base OpenGL component). Mesa is the canonical open-source 3D
## graphics stack: in the v1 minimal configuration (Wayland + swrast,
## no GLX, no GLVND) it provides libEGL.so / libGLESv2.so / libgbm.so
## — the three ABIs Wayland compositors hard-require from the host.
## (The classic ``libGL.so`` desktop GL entry point requires either
## GLX support or libglvnd as a vendor-neutral dispatch layer; neither
## is in v1 scope. Qt6OpenGL links against libGLESv2 directly when no
## libGL is present, so this is a viable subset.)
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
## We vendor the upstream 24.0.9 .tar.xz at
## ``recipes/packages/source/mesa/vendor/mesa-24.0.9.tar.xz`` and
## reference it via the canonical upstream URL recorded both in the
## ``versions:`` block AND the live ``fetch:`` block (the vendored copy
## is the on-host snapshot the canonical URL resolved to at
## recipe-authoring time — content-addressed via sha256). Matches the
## post-M9.R.14d.2 convention that EVERY ``fetch:`` URL points at the
## upstream URL, never at a host-absolute ``file:///`` path.
##
## ## Version choice — 24.0.9 (last 24.0.x before the 24.1+
## ``loader_wayland_helper.c`` regression, ships DRI_IMAGE_DRIVER v1)
##
## M9.R.71 established empirically that Mesa 23.3.6 boots sway into
## wlroots' HEADLESS backend on QEMU bochs-drm because wlroots' GBM
## probe (``egl.c:create_gbm_device``) fails with
## ``did not find extension DRI_IMAGE_DRIVER version 1``. The DRM
## backend refuses to initialise; sway runs but renders no frames to
## the framebuffer. Bumping to Mesa 24.0.x closes the gap.
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
## Mesa 24.0.9 PRE-DATES the ``loader_wayland_helper.c`` file
## entirely (verified against the vendored 24.0.9 tarball —
## ``src/loader/`` contains loader.c + loader_dri3_helper.c +
## loader_dri_helper.c only, no wayland helper). This gives us the
## DRI_IMAGE_DRIVER v1 surface wlroots 0.19's GBM-backed DRM backend
## needs while sidestepping the 24.1+ wayland-helper compile break.
##
## Once the v1 patching infrastructure lands (M9.M+), we can re-bump
## to a 24.2 / 24.3 stable with the one-line ``#include`` fix
## applied as a proper patch series.
##
## sha256 = 51aa686ca4060e38711a9e8f60c8f1efaa516baf411946ed7f2c265cd582ca4c
##  (computed locally over the vendored ``mesa-24.0.9.tar.xz``,
##  20,197,892 bytes; downloaded once from the upstream URL recorded
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
##                                 24.0.x still ships ``swrast`` as a
##                                 native gallium-drivers choice
##                                 (verified against 24.0.9
##                                 ``meson_options.txt``, choices list
##                                 includes ``swrast``). ``swrast`` on
##                                 24.0 builds the pure-C softpipe
##                                 path when LLVM is disabled. No
##                                 hardware drivers (i915, iris,
##                                 radeon, nouveau, etc.) — these
##                                 would pull libpciaccess + LLVM +
##                                 kernel-DRM deps far beyond v1
##                                 scope. swrast is enough for KF6 /
##                                 GNOME / Qt6 to link + run their
##                                 software-fallback paths.
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
    ##
    ## M9.R.78.1: bumped 23.3.6 -> 24.0.9 to publish
    ## DRI_IMAGE_DRIVER v1 (wlroots 0.19 GBM-EGL probe requirement).
    "24.0.9":
      sourceRevision = "mesa-24.0.9"
      sourceUrl = "https://archive.mesa3d.org/mesa-24.0.9.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/mesa/mesa"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## Upstream URL pinned per the post-M9.R.14d.2 convention; the
    ## convention layer's argv carries this URL verbatim so the
    ## engine's content-addressed cache fingerprint stays stable
    ## across rebuilds.
    ##
    ## sha256 was computed over the vendored 20,197,892-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://archive.mesa3d.org/mesa-24.0.9.tar.xz"
    sha256: "51aa686ca4060e38711a9e8f60c8f1efaa516baf411946ed7f2c265cd582ca4c"
    extractStrip: 1

  nativeBuildDeps:
    ## Mesa's configure and code-generation scripts require Mako. Keep the
    ## module-bearing source Python first so transitive bare Python profiles
    ## from Meson cannot shadow it.
    "python3-with-modules"
    ## meson is the build-system driver.
    "meson >=1.3"
    ## ninja is meson's default backend.
    "ninja >=1.10"
    ## pkg-config is used by meson to discover dependencies.
    "pkg-config"
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
      let pkg = meson_package(srcDir = "./src", configureOptions = opts,
        extraEnv = @[("PYTHONDONTWRITEBYTECODE", "1")])
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

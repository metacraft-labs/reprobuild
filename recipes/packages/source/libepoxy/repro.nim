## Source-from-tarball libepoxy recipe — M9.R.15b GNOME-stack
## foundation, prereq of gtk4.
##
## libepoxy is gtk4's OpenGL function-pointer-management library —
## a thin shim that hides the per-platform glXGetProcAddress /
## eglGetProcAddress / wglGetProcAddress dance behind a single C
## API. gtk4's GL backend short-fails configure if libepoxy is
## missing.
##
## ## Why libepoxy matters for the v1 desktop story
##
## gtk4 4.22.x ships an OpenGL-accelerated renderer (GskGLRenderer)
## as its default; the Vulkan renderer is a build-time opt-in we
## leave disabled for v1. The GL renderer's runtime entrypoints
## resolve through ``libepoxy.so`` — gtk4's ``gdk/gdkglcontext.c``
## includes ``<epoxy/gl.h>`` unconditionally. The v1 build sets
## ``glx=false`` + ``x11=false`` (pure Wayland) and leaves
## ``egl=true`` so EGL on Wayland works.
##
## ## sha256 strategy
##
## Per the network + audio batch convention (matching alsa-lib + the
## kernel), the live ``fetch:`` URL points at upstream directly (no
## vendoring). libepoxy's canonical release tarball is the GitHub
## ``/archive/refs/tags/<tag>.tar.gz`` URL (upstream does not publish
## a release-asset tarball). Hash computed locally over the GitHub
## archive bytes — nixpkgs's ``fetchFromGitHub`` form uses a
## different stripped archive with a different hash so a direct
## SRI cross-check is not possible. Version cross-check holds:
## nixpkgs (2026-06) pins 1.5.10, the current upstream stable.
##
## ## Version choice — 1.5.10 (current upstream stable)
##
## libepoxy's last stable release is 1.5.10 (GitHub release tag
## ``1.5.10``, October 2022). The 1.5 ABI is what gtk4 4.22.x
## requires (``epoxy >=1.4`` per gtk4's meson.build).
##
## sha256 = a7ced37f4102b745ac86d6a70a9da399cc139ff168ba6b8002b4d8d43c900c15
##  (computed locally over the upstream GitHub archive at
##  ``github.com/anholt/libepoxy/archive/refs/tags/1.5.10.tar.gz``).
##
## ## Build shape
##
## Meson + ninja.
##
## ## Library artifacts
##
## libepoxy emits one shared library:
##
##   * ``libepoxy.so`` — the OpenGL function-pointer manager.
##
## We register the artifact as ``libEpoxy``.
##
## ## Configurables
##
## v1 ships NO configurables — meson options are pinned:
##
##   * ``egl=no``     — DISABLE EGL support. M9.R.15b honest deferral:
##                       the v1 from-source closure does not yet build
##                       mesa from source, so the ``EGL/eglplatform.h``
##                       header (which ships in ``libegl-dev`` on debian
##                       or in the mesa ``out`` output on nix) is not on
##                       the include search path. The upstream meson
##                       build emits ``include/epoxy/egl_generated.h``
##                       containing ``#include "EGL/eglplatform.h"`` if
##                       egl=yes, which then fails compile. M9.R.15c
##                       must lift this to ``egl=yes`` after a from-
##                       source mesa / libegl-headers recipe lands.
##                       Downstream impact: gtk4's Wayland GL renderer
##                       cannot resolve EGL function pointers through
##                       libepoxy — gtk4 must use its software renderer
##                       or fall back to dlopen'd EGL until M9.R.15c.
##   * ``glx=no``     — drop GLX (X11-only; v1 is pure Wayland).
##   * ``x11=false``  — drop X11 dependencies entirely.
##   * ``tests=false`` — skip the upstream test suite.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package libepoxySource:
  ## From-source libepoxy — GNOME-stack foundation for gtk4.

  versions:
    "1.5.10":
      sourceRevision = "1.5.10"
      sourceUrl = "https://github.com/anholt/libepoxy/archive/refs/tags/1.5.10.tar.gz"
      sourceRepository = "https://github.com/anholt/libepoxy"

  fetch:
    url: "https://github.com/anholt/libepoxy/archive/refs/tags/1.5.10.tar.gz"
    sha256: "a7ced37f4102b745ac86d6a70a9da399cc139ff168ba6b8002b4d8d43c900c15"
    extractStrip: 1

  nativeBuildDeps:
    "meson >=0.55"
    "ninja >=1.10"
    "gcc >=11"
    ## python3 is invoked at build time by libepoxy's
    ## ``src/gen_dispatch.py`` to generate the dispatch tables from
    ## the Khronos XML registry shipped in the tree.
    "python3"

  buildDeps:
    ## v1 sets x11=false so libX11 is not required. The wayland-EGL
    ## path resolves through the system EGL implementation (mesa);
    ## EGL is dlopen'd at runtime, no link-time dep needed.
    discard

  config:
    discard

  library libEpoxy:
    ## ``libepoxy.so`` — OpenGL function-pointer manager. Consumed
    ## by gtk4's GL renderer.
    discard

  build:
    setCurrentOwningPackageOverride("libepoxySource")
    try:
      let opts = @[
        "egl=no",
        "glx=no",
        "x11=false",
        "tests=false",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libEpoxy")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard

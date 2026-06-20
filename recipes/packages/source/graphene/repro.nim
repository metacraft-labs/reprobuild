## Source-from-tarball graphene recipe — M9.R.15b GNOME-stack
## foundation, prereq of gtk4 + mutter.
##
## graphene is a tiny C library that provides typed vec/mat/quaternion
## primitives + SIMD-accelerated math. gtk4 uses it as its low-level
## graphics-types layer; mutter consumes it via the
## ``graphene-gobject-1.0`` pkg-config name to interop with its scene-
## graph. Both gtk4 and mutter FAIL `meson setup` if graphene is
## missing — this recipe is the from-source side of that edge.
##
## ## Why graphene matters for the v1 desktop story
##
## gtk4's ``meson.build`` declares ``graphene-1.0 >=1.5.1`` and mutter
## 47.10's ``src/meson.build:109`` declares ``graphene-gobject-1.0``.
## The GObject-introspection-enabled flavour exposes the same types
## via GObject's type system so language bindings (gjs, pygobject)
## can consume graphene types transparently. The v1 mutter build
## sets ``introspection=false`` but still depends on the
## ``graphene-gobject-1.0`` pkg-config name (the .pc file is
## installed regardless of whether the .gir is built).
##
## ## sha256 strategy
##
## Per the network + audio batch convention (matching alsa-lib + the
## kernel), the live ``fetch:`` URL points at upstream directly (no
## vendoring). graphene's canonical release tarball is the GitHub
## ``/archive/refs/tags/<tag>.tar.gz`` URL (upstream does not publish
## a release-asset tarball; the GitHub-generated archive is the
## reference distribution; nixpkgs's ``fetchFromGitHub`` form uses
## a different stripped archive with a different hash, so we cannot
## cross-check directly against nixpkgs's SRI hash — instead the
## hash is computed locally over the GitHub archive bytes).
##
## ## Version choice — 1.10.8 (current upstream stable)
##
## graphene's last stable release is 1.10.8 (GitHub release tag
## ``1.10.8``, January 2023). The 1.10 line ships the ``graphene-1.0``
## ABI both gtk4 4.x and mutter 47.x require. nixpkgs (2026-06) pins
## 1.10.8 too — see ``pkgs/by-name/gr/graphene/package.nix``.
##
## sha256 = 922dc109d2dc5dc56617a29bd716c79dd84db31721a8493a13a5f79109a4a4ed
##  (computed locally over the upstream GitHub archive at
##  ``github.com/ebassi/graphene/archive/refs/tags/1.10.8.tar.gz``).
##
## ## Build shape
##
## Meson + ninja. The c_cpp_meson convention (M9.K) reads the
## ``fetch:`` and ``mesonOptions:`` blocks off the recipe's
## registries and lowers them into a fetch action + a ``meson setup``
## + a ``ninja`` compile + a ``meson install`` chain.
##
## ## Library artifacts
##
## graphene's meson build emits one shared library (and the matching
## ``graphene-gobject-1.0`` pkg-config wrapper alias):
##
##   * ``libgraphene-1.0.so`` — the math-primitives library gtk4 +
##                              mutter + libclutter all link against.
##
## We register the artifact under the package-level identifier
## ``libGraphene`` (the ``-1.0`` ABI-version suffix is stripped per
## the libGlib2 / libPango precedent).
##
## ## Configurables
##
## v1 ships NO configurables — meson options are pinned:
##
##   * ``introspection=disabled`` — drop the g-ir-scanner dep (the
##                                   downstream v1 closure does not
##                                   build gobject-introspection from
##                                   source yet).
##   * ``gtk_doc=false``          — drop the gtk-doc HTML-reference
##                                   build (docbook + xsltproc not in
##                                   the v1 closure).
##   * ``installed_tests=false``  — skip the installed test programs.
##   * ``tests=false``            — skip the upstream test suite.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package grapheneSource:
  ## From-source graphene — GNOME-stack foundation for gtk4 + mutter.

  versions:
    "1.10.8":
      sourceRevision = "1.10.8"
      sourceUrl = "https://github.com/ebassi/graphene/archive/refs/tags/1.10.8.tar.gz"
      sourceRepository = "https://github.com/ebassi/graphene"

  fetch:
    ## Upstream GitHub archive URL — first-build out-of-band fetch,
    ## then cached by the M9.K fetch action keyed on
    ## (url, sha256, extractStrip).
    url: "https://github.com/ebassi/graphene/archive/refs/tags/1.10.8.tar.gz"
    sha256: "922dc109d2dc5dc56617a29bd716c79dd84db31721a8493a13a5f79109a4a4ed"
    extractStrip: 1

  nativeBuildDeps:
    "meson >=0.55"
    "ninja >=1.10"
    "gcc >=11"
    ## python3 is invoked at build time by graphene's meson scripts
    ## to generate the per-type accessor headers from the
    ## ``src/graphene-*.c`` source templates.
    "python3"

  buildDeps:
    ## glib2 is graphene's only library dependency at the C level —
    ## graphene's GObject-introspection wrapper exposes the math
    ## primitives via GObject's type system, so libgobject-2.0 +
    ## libglib-2.0 are both linked.
    "glib2 >=2.62"

  config:
    ## No prefix lifted from `mesonOptions:`; flags inlined in the `build:` block.
    discard

  library libGraphene:
    ## ``libgraphene-1.0.so`` — math primitives (vec3/vec4/mat4/quat).
    ## Consumed by gtk4 (via ``graphene-1.0``) and mutter (via
    ## ``graphene-gobject-1.0``). v1 records the artifact only.
    discard

  build:
    setCurrentOwningPackageOverride("grapheneSource")
    try:
      let opts = @[
        "introspection=disabled",
        "gtk_doc=false",
        "installed_tests=false",
        "tests=false",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libGraphene")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO: derive runtime closure from DT_NEEDED inspection.
    discard

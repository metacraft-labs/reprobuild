## Source-from-tarball glib2 recipe — the FIFTEENTH real from-source
## production recipe to exercise the M9.H/I/K trio.
##
## Follows the dbus-broker / libdrm / wayland / wlroots / sway /
## linux-kernel / libxkbcommon / pixman / libinput / cairo / pango /
## gdk-pixbuf (eleven meson recipes), the json-c CMake recipe, and the
## expat autotools recipe. glib2's unique coverage angle vs the prior
## fourteen recipes is the FOUR-LIBRARY single-package shape: glib2
## emits FOUR shared objects from a single meson build
## (``libglib-2.0.so`` + ``libgobject-2.0.so`` + ``libgio-2.0.so`` +
## ``libgmodule-2.0.so``) all sharing the same SONAME prefix but
## shipping distinct ABIs. This is the third multi-library single-
## package shape (Wayland was the first with libwayland-client +
## libwayland-server, pango was the second with libpango +
## libpangocairo). The M3 artifact registry's per-package artifact
## list must accept all four ``library`` blocks under the same
## ``package`` macro — a regression that collapsed multi-library
## packages would surface in the test's artifact-count + per-artifact
## name pinning.
##
## ## Why glib2 matters for the v1 desktop story
##
## glib2 is the foundation library underpinning GTK, GNOME, gdk-pixbuf,
## pango, and a wide swath of GObject-based desktop infrastructure.
## libglib-2.0 provides the generic C utilities (data structures,
## main-loop, threading primitives, character-set conversion).
## libgobject-2.0 provides the GObject type system (properties,
## signals, runtime type info). libgio-2.0 provides the I/O layer
## (file/stream/socket abstractions + GSettings + GDBus). libgmodule
## provides the portable shared-library loader. Every prior from-
## source recipe consuming a GObject library
## (gdk-pixbuf, pango, cairo's font-config glue) pins
## ``glib >=2.62`` in its ``uses:`` block; this recipe is the
## upstream-source side of those dependency edges.
##
## ## sha256 strategy
##
## We vendor the upstream 2.82.5 .tar.xz at
## ``recipes/packages/source/glib2/vendor/glib-2.82.5.tar.xz`` and
## reference it via a ``file://`` URL. The download.gnome.org release
## URL is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's
## emitted fetch action is offline-reproducible.
##
## ## Version choice — 2.82.5 (current upstream stable)
##
## download.gnome.org publishes glib releases at
## ``https://download.gnome.org/sources/glib/`` and 2.82.5 is the
## current stable in the 2.82.x line as of mid-2026. The glib2 ABI
## has been stable since the 2.62 cut — anything ``>=2.62`` covers
## the prior recipe consumptions.
##
## sha256 = 05c2031f9bdf6b5aba7a06ca84f0b4aced28b19bf1b50c6ab25cc675277cbc3f
##  (computed locally over the vendored ``glib-2.82.5.tar.xz``,
##  5,554,704 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_meson convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``mesonOptions:`` block off this package's
## registries and lowers them into:
##
##   1. a fetch BuildAction whose argv carries the URL + sha256 +
##      extract dest (content-addressed so a re-run hits the cache).
##   2. a ``meson setup`` configure BuildAction that depends on the
##      fetch action and passes every flag in ``mesonOptions:`` to
##      ``meson setup``, in declared order.
##   3. a ``ninja`` compile BuildAction (M9.L).
##   4. install/output collection actions for the four library
##      artifacts (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ninja-spawn + install glue lands in M9.L; the recipe
## records the library artifacts via the four ``library`` blocks so
## the M9.K artifact registry already knows what shared objects to
## expect.
##
## ## Library artifacts
##
## glib2's meson build emits four shared objects from one build tree:
##
##   * ``libglib-2.0.so`` — core C utilities (data structures,
##                          main-loop, threading, charset).
##   * ``libgobject-2.0.so`` — GObject type system (properties,
##                              signals, runtime type info).
##   * ``libgio-2.0.so`` — I/O layer (file / stream / socket / GSettings
##                          / GDBus).
##   * ``libgmodule-2.0.so`` — portable shared-library loader.
##
## We register the four artifacts under the package-level
## identifiers ``libGlib2`` / ``libGObject`` / ``libGio`` / ``libGModule``
## (the ``-2.0`` ABI-version suffix is stripped and the hyphenated
## SONAME is camelCased to stay within Nim identifier conventions,
## matching the pango / gdk-pixbuf precedents).
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``tests=false``            — skip the upstream test suite to
##                                    keep the build hermetic + fast.
##   * ``documentation=false``    — skip the documentation build.
##   * ``man-pages=disabled``     — skip man-page generation.
##   * ``introspection=disabled`` — skip GObject Introspection (drops
##                                    the g-ir-scanner toolchain dep
##                                    the v1 desktop story doesn't
##                                    exercise).
##   * ``nls=disabled``           — skip the native-language-support
##                                    translation build (gettext
##                                    plumbing not needed for the v1
##                                    desktop story).
##   * ``xattr=false``            — skip extended-attribute support
##                                    (libattr dependency not needed
##                                    for the v1 desktop story).
##   * ``--buildtype=release``    — release-mode optimisation; matches
##                                    the sibling from-source recipes.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a developer variant that
## flips ``introspection=enabled`` for GNOME-shell developer bundles).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package glib2Source:
  ## From-source glib2 — fifteenth M9.H/I/K production recipe and the
  ## third multi-library single-package shape (FOUR libraries) after
  ## Wayland (two libraries) + pango (two libraries).
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``mesonOptions:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"meson"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags. Four library artifacts recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.gnome.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream GNOME gitlab
    ## project --- glib's canonical home post-freedesktop-migration.
    "2.82.5":
      sourceRevision = "2.82.5"
      sourceUrl = "https://download.gnome.org/sources/glib/2.82/glib-2.82.5.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/glib"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 5,554,704-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/glib2/vendor/glib-2.82.5.tar.xz"
    sha256: "05c2031f9bdf6b5aba7a06ca84f0b4aced28b19bf1b50c6ab25cc675277cbc3f"
    extractStrip: 1

  nativeBuildDeps:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``. glib2 2.82 requires
    ## meson 0.79 for the ``-Dnls=disabled`` + ``-Dxattr=false``
    ## option semantics introduced in that release.
    "meson >=0.79"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — glib2 is C99 with light use of
    ## GLib-style autoconf macros via meson's gnome module.
    "gcc >=11"

  buildDeps:
    ## pcre2 is the regex engine glib's GRegex API delegates to.
    ## glib2 2.82 requires pcre2 10.34 for the JIT-compile API
    ## semantics it relies on.
    "pcre2 >=10.34"
    ## libffi is the foreign-function-interface library GObject's
    ## closure / marshaller layer uses for runtime-typed signal
    ## dispatch.
    "libffi"
    ## zlib is required by GIO for the gzip / deflate stream encoders
    ## and by GResource's optional compression layer.
    "zlib"

  mesonOptions:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: meson evaluates options
    ## left-to-right and the ``--buildtype=release`` sentinel lives at
    ## the tail so any override (e.g. a future debug-build variant)
    ## can append ``--buildtype=debug`` later without re-ordering this
    ## block.
    ##
    ## ``tests=false`` skips the upstream test suite (heaviest portion
    ## of the build, not needed at runtime).
    ## ``documentation=false`` skips the documentation build.
    ## ``man-pages=disabled`` skips man-page generation.
    ## ``introspection=disabled`` skips GObject Introspection (drops
    ## the g-ir-scanner toolchain dep).
    ## ``nls=disabled`` skips the native-language-support translation
    ## build.
    ## ``xattr=false`` skips extended-attribute support.
    "-Dtests=false"
    "-Ddocumentation=false"
    "-Dman-pages=disabled"
    "-Dintrospection=disabled"
    "-Dnls=disabled"
    "-Dxattr=false"
    "--buildtype=release"

  library libGlib2:
    ## ``libglib-2.0.so`` — the core C utilities library (data
    ## structures, main-loop, threading primitives, character-set
    ## conversion) consumed by every downstream GObject library.
    ## v1 records the artifact only; the per-artifact build body
    ## lands in M9.L when the convention's ninja-spawn + install-glue
    ## closes.
    discard

  library libGObject:
    ## ``libgobject-2.0.so`` — the GObject type system (properties,
    ## signals, runtime type info) every GObject library subclasses.
    ## v1 records the artifact only.
    discard

  library libGio:
    ## ``libgio-2.0.so`` — the I/O layer (file / stream / socket
    ## abstractions + GSettings + GDBus). Consumed by every
    ## downstream desktop component for D-Bus messaging + settings
    ## storage. v1 records the artifact only.
    discard

  library libGModule:
    ## ``libgmodule-2.0.so`` — the portable shared-library loader.
    ## Consumed by gdk-pixbuf's loader-plugin discovery + by GLib
    ## itself for dlopen-style module loading. v1 records the
    ## artifact only.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

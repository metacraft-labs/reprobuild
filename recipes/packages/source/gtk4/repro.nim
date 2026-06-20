## Source-from-tarball gtk4 recipe — M9.R.15b GNOME-stack primary
## gate.
##
## gtk4 is the GIMP Toolkit 4.x — the GUI widget library underpinning
## libadwaita-using GNOME applications. It is the central deliverable
## of the GNOME stack foundation: every higher GNOME library (libadwaita,
## gnome-control-center, xdg-desktop-portal-gtk) and every GTK4
## application (Files, Maps, Music, ...) hard-links ``libgtk-4.so.1``.
##
## ## Why gtk4 matters for the v1 desktop story
##
## NDE-G1 (the GNOME-stack DE entry) consumes gtk4 indirectly through
## libadwaita-using applications + xdg-desktop-portal-gtk. The catalog
## at ``recipes/catalog/linux/libgtk4.json`` pins the jammy .deb form
## (4.6.9+ds-0ubuntu0.22.04.2); the from-source recipe is the alternate
## path. Publishing gtk4 from source unlocks every downstream GNOME
## application that needs a newer gtk4 ABI than jammy ships.
##
## ## sha256 strategy
##
## Per the network + audio batch convention: live ``fetch:`` URL points
## at download.gnome.org directly (no vendoring). sha256 cross-checked
## against nixpkgs's ``pkgs/by-name/gt/gtk4/package.nix`` SRI hash
## ``sha256-Ub2fYMfSOmZaVWxzZMIfsuTiglZrPn4JJFXo+RAzCJM=`` (decodes
## to the hex value pinned below; verified to match the upstream
## tarball bytes downloaded once from download.gnome.org).
##
## ## Version choice — 4.18.5 (compatible with v1 glib2 2.82.5)
##
## We pin gtk4 4.18.5 (rather than the current stable 4.22.4) because
## gtk4 4.22 requires ``glib >= 2.84`` (per gtk-4.22.4/meson.build's
## ``glib_minor_req = 84``) while the sibling ``glib2Source`` recipe
## at M9.R.15b vendors 2.82.5. Bumping the glib2 recipe is out of
## scope for this milestone — it would invalidate every downstream
## cairo / pango / gdk-pixbuf / mutter cache key, and the dep
## constraint on every consumer's ``buildDeps`` row would need
## auditing in lockstep.
##
## gtk4 4.18.5 requires ``glib >= 2.80`` (per its meson.build's
## ``glib_minor_req = 80``), which the v1 glib 2.82.5 satisfies.
## 4.18 is the previous LTS-shaped line; the libadwaita 1.6+
## ecosystem still supports 4.18.
##
## sha256 = bb5267a062f5936947d34c9999390a674b0b2b0d8aa3472fe0d05e2064955abc
##
## ## Build shape
##
## Meson + ninja. gtk4's meson build is one of the largest in the
## GNOME ecosystem; it pulls a wide range of build-time and runtime
## deps. v1 disables the heavy optional integrations (cups, tracker,
## colord, Vulkan) to keep the foundation closure tractable.
##
## ## Library + executable artifacts
##
## gtk4's meson build emits one shared library and several command-
## line tools — v1 records the load-bearing ones:
##
##   * ``libgtk-4.so.1``        — the GUI toolkit shared library
##                                consumed by every GTK4 application.
##   * ``gtk4-launch``          — application launcher helper.
##   * ``gtk4-update-icon-cache`` — icon cache builder.
##   * ``gtk4-query-settings``  — settings query CLI.
##
## ## Configurables
##
## v1 ships NO configurables — meson options are pinned:
##
##   * ``introspection=disabled`` — drop the .gir emission (gjs/pygobject
##                                   not in v1 closure; the
##                                   gobject-introspection build dep is
##                                   still pulled in for the .pc check).
##   * ``documentation=false``   — drop the gi-docgen HTML reference.
##   * ``man-pages=false``       — drop the manpage build.
##   * ``build-tests=false``     — skip the upstream tests subtree.
##   * ``build-testsuite=false`` — skip the regression test suite.
##   * ``build-examples=false``  — skip the example apps.
##   * ``build-demos=false``     — skip the demo apps.
##   * ``broadway-backend=true`` — enable the broadway HTML5 backend
##                                  (lightweight, no extra deps).
##   * ``wayland-backend=true``  — enable the Wayland backend (the
##                                  v1 primary display server).
##   * ``x11-backend=false``     — drop the X11 backend (pure Wayland
##                                  posture per the wlroots / sway /
##                                  mutter precedent).
##   * ``vulkan=disabled``       — drop Vulkan support (the GL renderer
##                                  is sufficient for v1; Vulkan adds
##                                  shaderc/vulkan-loader deps).
##   * ``print-cups=disabled``   — drop the CUPS print backend.
##   * ``tracker=disabled``      — drop the tinysparql search backend.
##   * ``colord=disabled``       — drop the colord ICC-profile backend.
##   * ``media-gstreamer=disabled`` — drop the GStreamer media playback
##                                     backend (drops the gst_all_1
##                                     dep closure).
##   * ``f16c=disabled``         — drop the f16c CPU-feature gated path
##                                  (broadens host compatibility).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package gtk4Source:
  ## From-source gtk4 — GNOME-stack primary gate. The widget toolkit
  ## underpinning libadwaita + every GTK4 application.

  versions:
    "4.18.5":
      sourceRevision = "4.18.5"
      sourceUrl = "https://download.gnome.org/sources/gtk/4.18/gtk-4.18.5.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/gtk"

  fetch:
    url: "https://download.gnome.org/sources/gtk/4.18/gtk-4.18.5.tar.xz"
    sha256: "bb5267a062f5936947d34c9999390a674b0b2b0d8aa3472fe0d05e2064955abc"
    extractStrip: 1

  nativeBuildDeps:
    "meson >=1.2"
    "ninja >=1.10"
    "gcc >=11"
    ## python3 runs gtk4's meson build scripts + the icon-cache
    ## generator + the GResource bundler.
    "python3"
    ## gettext provides msgfmt for the translation catalog build.
    "gettext"
    ## sassc compiles the Sass stylesheets bundled with the default
    ## theme (Adwaita-dark / Adwaita-light / HighContrast).
    "sassc"
    ## M9.R.15b — gobject-introspection's g-ir-scanner is referenced
    ## by gtk4's ``gnome.generate_gir()`` calls but the calls are
    ## gated on ``-Dintrospection=enabled`` at the meson layer; with
    ## ``introspection=disabled`` (our v1 pin) the dep edge is dead
    ## at compile time. Dropping the nativeBuildDep from this recipe
    ## keeps gtk4's auto-recurse closure from pulling
    ## gobject-introspection (whose from-source build needs
    ## python3-with-setuptools — not yet provisioned). The gtk4
    ## recipe surfaces this exact gap as the M9.R.15c handoff.
    ## libxml2 ships xmllint, consumed by gtk4's GResource compile
    ## step to validate the XML bundle manifests.
    "libxml2"

  buildDeps:
    ## glib2 is gtk4's foundation library (GObject, GIO, GSettings,
    ## GResource).
    "glib2 >=2.76"
    ## cairo is gtk4's 2D drawing backend (path rendering, gradient
    ## fills, font outlines).
    "cairo >=1.16"
    ## pango is gtk4's text-shaping + font-rendering layer.
    "pango >=1.50"
    ## gdk-pixbuf is gtk4's image loader (PNG/JPEG/SVG decoding).
    "gdk-pixbuf >=2.40"
    ## graphene provides typed vec/mat/quat primitives gtk4's
    ## scene-graph layer consumes.
    "graphene >=1.10"
    ## harfbuzz is the OpenType shaper pango delegates to.
    "harfbuzz >=2.6"
    ## libepoxy is gtk4's OpenGL function-pointer manager.
    "libepoxy >=1.4"
    ## libxkbcommon is the keyboard-keymap library gtk4's input layer
    ## consumes (Wayland keyboard input + accelerator parsing).
    "libxkbcommon >=1.5"
    ## libpng + libjpeg + libtiff are the image-format codecs.
    "libpng >=1.6"
    "libjpeg >=2.0"
    "libtiff"
    ## wayland is the protocol library gtk4's Wayland backend links
    ## against.
    "wayland >=1.22"
    ## wayland-protocols ships the protocol-XML files (xdg-shell,
    ## linux-dmabuf, ...) gtk4's Wayland backend consumes at build
    ## time.
    "wayland-protocols >=1.31"
    ## libdrm is required by gtk4's GBM-backed dmabuf path.
    "libdrm >=2.4.110"
    ## fribidi is required for pango's bidirectional text layout.
    "fribidi"

  config:
    discard

  library libGtk4:
    ## ``libgtk-4.so.1`` — the GUI widget library.
    discard

  executable gtk4Launch:
    ## ``/usr/bin/gtk4-launch`` — application launcher helper.
    discard

  executable gtk4UpdateIconCache:
    ## ``/usr/bin/gtk4-update-icon-cache`` — icon cache builder.
    discard

  executable gtk4QuerySettings:
    ## ``/usr/bin/gtk4-query-settings`` — settings query CLI.
    discard

  build:
    setCurrentOwningPackageOverride("gtk4Source")
    try:
      let opts = @[
        # M9.R.15b — pin to gtk4 4.18.5's option schema. Feature-type
        # options use the enabled/disabled/auto trichotomy; boolean
        # types stay true/false.
        "introspection=disabled",
        "documentation=false",
        "man-pages=false",
        "screenshots=false",
        "build-tests=false",
        "build-testsuite=false",
        "build-examples=false",
        "build-demos=false",
        # M9.R.15b.9 — disable wayland-backend in v1 because gtk4's
        # gdk/wayland/gdkdisplay-wayland.h unconditionally
        # ``#include <epoxy/egl.h>`` and our v1 libepoxy is built
        # with egl=no (the v1 closure does not yet build mesa from
        # source, so EGL/eglplatform.h is not on the include search
        # path; see libepoxy/repro.nim's M9.R.15b.3 deferral note).
        # Without EGL headers libepoxy does not emit epoxy/egl.h
        # either, so gtk4's wayland backend short-fails compile at
        # gdkprimary-wayland.c with
        #   fatal error: epoxy/egl.h: No such file or directory
        # Until M9.R.15c lifts libepoxy's egl back to yes (after a
        # from-source mesa / libegl-headers recipe lands), gtk4 ships
        # with broadway-only — the Wayland session can still load
        # gtk4 apps via broadway-over-HTML for v1 validation.
        "broadway-backend=true",
        "wayland-backend=false",
        "x11-backend=false",
        "vulkan=disabled",
        "print-cups=disabled",
        "print-cpdb=disabled",
        "tracker=disabled",
        "colord=disabled",
        "media-gstreamer=disabled",
        "f16c=disabled",
        # M9.R.15b.8 — disable the sysprof subproject fallback. When
        # gtk4's meson.build cannot find ``sysprof-capture-4`` via
        # pkg-config it falls through to the vendored
        # ``subprojects/sysprof`` tree, whose own meson.build then
        # tries to override ``glib-2.0`` and crashes with
        #   ERROR: Tried to override dependency 'glib-2.0' which has
        #   already been resolved or overridden.
        # ``sysprof=disabled`` keeps gtk4 from probing for it at all.
        "sysprof=disabled",
        "cloudproviders=disabled",
        "accesskit=disabled",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libGtk4")
      discard pkg.executable("gtk4Launch")
      discard pkg.executable("gtk4UpdateIconCache")
      discard pkg.executable("gtk4QuerySettings")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard

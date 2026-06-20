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
## ## Version choice — 4.22.4 (current upstream stable)
##
## gtk4 4.22.4 is the current stable in the 4.22.x line as of mid-2026
## (matches the nixpkgs pin). The 4.x ABI is stable since 4.0; any
## ``>=4.10`` covers libadwaita 1.x's consumption.
##
## sha256 = 51bd9f60c7d23a665a556c7364c21fb2e4e282566b3e7e092455e8f910330893
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
    "4.22.4":
      sourceRevision = "4.22.4"
      sourceUrl = "https://download.gnome.org/sources/gtk/4.22/gtk-4.22.4.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/gtk"

  fetch:
    url: "https://download.gnome.org/sources/gtk/4.22/gtk-4.22.4.tar.xz"
    sha256: "51bd9f60c7d23a665a556c7364c21fb2e4e282566b3e7e092455e8f910330893"
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
    ## gobject-introspection's g-ir-scanner is consumed at build
    ## time by gtk4's ``gnome.generate_gir()`` calls even when
    ## ``introspection=disabled`` (the meson helper probes for the
    ## scanner unconditionally; the actual .gir emission is gated
    ## on the option).
    "gobject-introspection"
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
        "introspection=disabled",
        "documentation=false",
        "man-pages=false",
        "build-tests=false",
        "build-testsuite=false",
        "build-examples=false",
        "build-demos=false",
        "broadway-backend=true",
        "wayland-backend=true",
        "x11-backend=false",
        "vulkan=disabled",
        "print-cups=disabled",
        "tracker=disabled",
        "colord=disabled",
        "media-gstreamer=disabled",
        "f16c=disabled",
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

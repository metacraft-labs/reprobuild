## Source-from-tarball mutter recipe — the SIXTEENTH real from-source
## production recipe to exercise the M9.H/I/K trio and the FIRST recipe
## in the GNOME stack batch (mutter / gdm / gnome-shell).
##
## Prior fifteen from-source recipes — twelve meson (dbus-broker, libdrm,
## wayland, wlroots, sway, libxkbcommon, pixman, libinput, cairo, pango,
## gdk-pixbuf, glib2), one make (linux-kernel), one CMake (json-c), one
## autotools (expat) — collectively covered every M9.I flag-injection
## channel at least once. mutter is the second meson-driven multi-
## artifact recipe to ship BOTH a library AND an executable from the
## same ``package`` macro (Wayland was the first with libwayland-client +
## libwayland-server + libwayland-cursor + wayland-scanner). The unique
## coverage angle here is the GNOME-shell-compositor pairing: mutter's
## meson build emits a single shared library (``libmutter-15.so``) that
## gnome-shell links against, and a standalone compositor binary
## (``mutter``) that can run as the Wayland session compositor outside
## the shell. The M3 artifact registry's per-package artifact list must
## keep ``dakLibrary`` and ``dakExecutable`` discriminators correctly
## distinguished WITHIN a single package's artifact set.
##
## ## Why mutter matters for the v1 desktop story
##
## mutter is the GNOME compositor: a Wayland compositor + window manager
## built on top of libclutter and libcogl (vendored upstream into the
## mutter tree post-3.36 to escape the libclutter ABI freeze).
## gnome-shell links against ``libmutter-15.so`` for its compositor
## glue, and the standalone ``mutter`` binary can drive a bare-bones
## Wayland session for embedded / headless deployments. NDE-G1 (the
## GNOME desktop entry) pins ``mutter >=47`` and the sibling
## ``gnomeShellSource`` recipe declares the same pin in its ``uses:``
## block.
##
## ## sha256 strategy
##
## We vendor the upstream 47.10 .tar.xz at
## ``recipes/packages/source/mutter/vendor/mutter-47.10.tar.xz`` and
## reference it via a ``file://`` URL. The download.gnome.org release
## URL is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 47.10 (current upstream stable in the 47.x line)
##
## download.gnome.org publishes mutter releases at
## ``https://download.gnome.org/sources/mutter/`` and 47.10 is the
## current stable in the 47.x line as of mid-2026. The 47.x series
## ships the libmutter-15 ABI consumed by GNOME shell 47.x; pinning
## the matching minor line keeps the gnome-shell <-> mutter ABI pair
## consistent.
##
## sha256 = ee8a583c2b6ff309b501dc97e7c0b4f11d6197a9529ed22247ee95e89663e969
##  (computed locally over the vendored ``mutter-47.10.tar.xz``,
##  6,860,276 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
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
##   4. install/output collection actions for the library + executable
##      artifacts (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ninja-spawn + install glue lands in M9.L; the recipe
## records the artifacts via one ``library`` block + one ``executable``
## block so the M9.K artifact registry already knows what shared
## object + binary to expect.
##
## ## Artifacts
##
## mutter's meson build emits one shared library + one standalone
## binary:
##
##   * ``libmutter-15.so`` — the compositor / window-manager library
##                            consumed by gnome-shell as its compositor
##                            glue layer.
##   * ``mutter`` — the standalone compositor binary that can drive a
##                   Wayland session outside gnome-shell.
##
## We register the library under the package-level identifier
## ``libMutter`` (the ``-15`` ABI-version suffix is stripped and the
## hyphen is dropped, matching the libglib-2.0 -> libGlib2 precedent),
## and the executable under ``mutterBin`` (the bare name ``mutter``
## would shadow the package macro's argument scope; the ``Bin`` suffix
## disambiguates the artifact identifier from the package name without
## colliding with the on-disk binary name -- M9.L's install path uses
## the artifact name as the recorded identifier but harvests
## ``$prefix/bin/mutter`` via the convention layer's binary-discovery
## glob, not via this identifier).
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``introspection=false`` — skip GObject Introspection (drops the
##                                g-ir-scanner toolchain dep the v1
##                                desktop story doesn't exercise).
##   * ``profiler=false``      — skip the Sysprof profiler integration
##                                (drops the libsysprof-capture dep,
##                                runtime-irrelevant for v1).
##   * ``tests=false``         — skip the upstream test suite to keep
##                                the build hermetic + fast.
##   * ``debug=false``         — disable debug assertions (matches the
##                                release-mode baseline).
##   * ``native_backend=true`` — enable the KMS/DRM native backend so
##                                mutter can drive bare-metal Wayland
##                                sessions (the NDE-G1 default).
##   * ``wayland=true``        — enable the Wayland compositor backend
##                                (the v1 desktop story is pure-
##                                Wayland; matches the wlroots / sway
##                                ``xwayland=disabled`` posture).
##   * ``x11=false``           — drop the X11-server backend (the v1
##                                desktop story is pure-Wayland).
##   * ``xwayland=false``      — drop the XWayland legacy-client
##                                support (matches the wlroots / sway
##                                ``xwayland=disabled`` posture).
##   * ``remote_desktop=false`` — drop the PipeWire / libei remote-
##                                 desktop backend (runtime-irrelevant
##                                 for v1).
##   * ``--buildtype=release`` — release-mode optimisation; matches
##                                the sibling from-source recipes.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. an X11-compat variant that
## flips ``x11=true`` for legacy bundles).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package mutterSource:
  ## From-source mutter — sixteenth M9.H/I/K production recipe and the
  ## FIRST recipe in the GNOME stack batch. Second meson-driven multi-
  ## artifact recipe to ship a library + an executable from the same
  ## ``package`` macro (Wayland was the first).
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``mesonOptions:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"meson"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags. Library + executable artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.gnome.org release tarball URL so a future maintainer
    ## running ``repro update-source`` can re-fetch from upstream; the
    ## live ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream GNOME gitlab
    ## project --- mutter's canonical home.
    "47.10":
      sourceRevision = "47.10"
      sourceUrl = "https://download.gnome.org/sources/mutter/47/mutter-47.10.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/mutter"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 6,860,276-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://download.gnome.org/sources/mutter/47/mutter-47.10.tar.xz"
    sha256: "ee8a583c2b6ff309b501dc97e7c0b4f11d6197a9529ed22247ee95e89663e969"
    extractStrip: 1

  nativeBuildDeps:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``. mutter 47.x requires
    ## meson 1.3 for its modern Wayland-protocol scanner integration.
    "meson >=1.3"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — mutter is C11 with light use of
    ## GLib-style autoconf macros via meson's gnome module.
    "gcc >=11"
    ## M9.R.15e.6 — gettext provides ``msgfmt`` (consumed by mutter's
    ## ``src/data/meson.build:1`` to compile the .po translation
    ## catalogs into .mo binaries). Without it meson setup short-fails:
    ##   ERROR: Program 'msgfmt' not found or not executable
    "gettext"
    ## M9.R.15e.6 — python3 runs mutter's per-keymap helper +
    ## clutter/cogl preamble generators at meson-setup + compile time.
    ## Same fix shape as gtk4 / glib2 / harfbuzz / fontconfig.
    "python3"

  buildDeps:
    ## glib2 is the foundation library mutter's compositor + window-
    ## manager layers consume (GObject type system, GMainLoop event
    ## loop, GSettings configuration). The sibling ``glib2Source``
    ## recipe vendors 2.82.5 to match.
    "glib2 >=2.62"
    ## libdrm is the KMS/DRM userspace library mutter's native backend
    ## consumes to drive bare-metal Wayland sessions. The sibling
    ## ``libdrmSource`` recipe vendors 2.4.124 to match.
    "libdrm >=2.4.110"
    ## wayland is the protocol library mutter's compositor backend
    ## consumes. The sibling ``waylandSource`` recipe vendors 1.25.0
    ## to match.
    "wayland >=1.22"
    ## M9.R.15e.5 — wayland-protocols ships the XML protocol-definition
    ## files (xdg-shell, linux-dmabuf, presentation-time, ...) mutter's
    ## Wayland backend consumes at build time. Stub routes through
    ## nixpkgs#wayland-protocols (.pc lives at share/pkgconfig).
    ## (``wayland-egl.pc`` is already provided by the ``waylandSource``
    ## sibling recipe's install tree, picked up via the existing
    ## ``wayland`` buildDep — no separate declaration needed.)
    "wayland-protocols >=1.31"
    ## libxkbcommon is the keyboard-keymap library mutter's seat /
    ## input layer consumes to translate raw evdev keycodes into XKB
    ## keysyms.
    "libxkbcommon >=1.5"
    ## libinput is the input-device hotplug + event library mutter
    ## consumes for keyboard / mouse / touchpad / tablet input.
    "libinput >=1.19"
    ## pixman is the pixel-region library mutter's renderer consumes
    ## for damage region tracking + software composition fallback.
    "pixman >=0.42"
    ## cairo is the 2D drawing backend mutter uses for X11-compat
    ## window decorations + on-screen overlays.
    "cairo >=1.16"
    ## pango is the text-shaping + font-rendering library mutter uses
    ## for window-title rendering + on-screen text overlays.
    "pango >=1.50"
    ## gdk-pixbuf is the image-loader library mutter uses for window
    ## icon decoding + background image loading.
    "gdk-pixbuf >=2.40"
    ## graphene is the math-primitives library (vec/mat/quat) mutter
    ## consumes for its scene-graph layer. Mutter's
    ## ``src/meson.build:109`` declares ``graphene-gobject-1.0`` and
    ## short-fails meson setup with
    ## ``ERROR: Dependency "graphene-gobject-1.0" not found`` when the
    ## graphene .pc is not on PKG_CONFIG_PATH. The sibling
    ## ``grapheneSource`` recipe (M9.R.15b.2) vendors 1.10.8 to match.
    "graphene >=1.10"
    ## harfbuzz is the OpenType shaper mutter's clutter+cogl layers
    ## consume directly (independent of pango).
    "harfbuzz >=2.6"
    ## fribidi is required for bidirectional text layout in mutter's
    ## window-title rendering path.
    "fribidi"
    ## libxml2 ships xmllint, consumed by mutter's GResource compile
    ## step + GSettings schema validation.
    "libxml2"
    ## M9.R.15e.3 — gsettings-desktop-schemas surfaces the GNOME GSettings
    ## schema set (a11y / calendar / default-apps / lockdown / peripherals
    ## / privacy / screen / sound / system / ...). mutter 47.x's
    ## ``src/meson.build:116`` declares the dep and short-fails meson
    ## setup with ``Dependency "gsettings-desktop-schemas" not found,
    ## tried pkgconfig`` when the .pc file is missing from
    ## ``PKG_CONFIG_PATH``. Routed through nixpkgs via the M9.R.15e.3
    ## stdlib stub; the .pc lives at ``share/pkgconfig`` which the
    ## from-source resolver already threads (M9.R.14e.1).
    "gsettings-desktop-schemas"
    ## M9.R.15e.4 — mutter 47.x's ``src/meson.build`` declares the
    ## following unconditional pkgconfig dependencies that the prior
    ## buildDeps row did not cover. Each maps to a stdlib stub
    ## pointing at the matching nixpkgs derivation.
    ##
    ## * ``atk`` (line 126) — GNOME accessibility toolkit, via
    ##   ``nixpkgs#atk`` (aliased to at-spi2-core upstream).
    ## * ``colord`` (line 127) — color-management daemon.
    ## * ``lcms2`` (line 128) — Little CMS 2 color transforms.
    ## * ``libei`` + ``libeis`` (lines 130-131) — Emulated Input
    ##   protocol library; nixpkgs ships both client + server .pc
    ##   files from one derivation.
    ## * ``gl`` + ``egl`` + ``glesv2`` (lines 189/195/209) — OpenGL
    ##   vendor-neutral dispatch via ``nixpkgs#libglvnd`` (gated on
    ##   the cogl/cogl-pango/clutter compile path).
    ## * ``libgbm`` (line 251, gated on native_backend=true) — mesa
    ##   GBM userspace via ``nixpkgs#libgbm``.
    ## * ``gudev`` (line 237) + ``udev`` (line 238) — libgudev GLib
    ##   wrapper + udev.pc from systemd's -dev output.
    "atk"
    "colord"
    "lcms2"
    "libei"
    "libeis"
    "gl"
    "egl"
    "glesv2"
    "libgbm"
    "gudev"
    "udev"
    "libudev"

  config:
    ## No prefix lifted from `mesonOptions:`; flags inlined in the `build:` block.
    discard
  library libMutter:
    ## ``libmutter-15.so`` — the compositor / window-manager library
    ## consumed by gnome-shell as its compositor glue layer. The
    ## ``-15`` ABI-version suffix is stripped from the package-level
    ## identifier per the glib2 / pango precedent (the on-disk SONAME
    ## still carries the suffix). v1 records the artifact only; the
    ## per-artifact build body lands in M9.L when the convention's
    ## ninja-spawn + install-glue closes.
    discard

  executable mutterBin:
    ## ``/usr/bin/mutter`` — the standalone compositor binary that can
    ## drive a Wayland session outside gnome-shell. NDE-G1's bare-
    ## bones embedded-mutter session.service would ``ExecStart`` this
    ## binary directly. The ``Bin`` suffix on the artifact identifier
    ## disambiguates from the package-name scope without colliding
    ## with the on-disk binary name (M9.L's install path uses the
    ## artifact-name -> $prefix/bin/$name mapping but the convention
    ## layer's binary-discovery glob recognises ``mutter`` as the
    ## upstream-emitted basename).
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `meson_package(...)` constructor.
    setCurrentOwningPackageOverride("mutterSource")
    try:
      let opts = @[
        # M9.R.15b.1 — mutter 47.10's `tests` and `libdisplay_info`
        # options are meson `feature` types (enabled/disabled/auto); the
        # plain bool form `tests=false` short-fails meson setup with
        # ``Value "false" ... is not one of the choices``. Use the
        # feature-shape verbatim. `debug` is not a recipe-level option
        # for mutter (debug-mode is selected via the global buildtype
        # which `meson_package` pins to `release`); drop the no-op
        # `debug=false`.
        "introspection=false",
        "profiler=false",
        "tests=disabled",
        "native_backend=true",
        "wayland=true",
        "x11=false",
        "xwayland=false",
        "remote_desktop=false",
        # M9.R.15b.1 — drop the heavy optional integrations: each pulls
        # one or more deps that the v1 from-source closure does not yet
        # provide (gnome-desktop-4, libwacom, libcanberra, libice/libsm,
        # libdisplay-info). Setting them false (booleans) or disabled
        # (features) keeps the v1 mutter binary minimal — bare Wayland
        # compositor + KMS/DRM backend, suitable for an embedded
        # mutter-only session.
        "libgnome_desktop=false",
        "libwacom=false",
        "sound_player=false",
        "startup_notification=false",
        "sm=false",
        "libdisplay_info=disabled",
        # Tests of cogl/clutter/mutter sub-trees are independent
        # booleans — disable explicitly so the overall `tests=disabled`
        # feature short-circuit is not partially defeated by the
        # cogl/clutter level booleans defaulting true.
        "cogl_tests=false",
        "clutter_tests=false",
        "mutter_tests=false",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libMutter")
      discard pkg.executable("mutterBin")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

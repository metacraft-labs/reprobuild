## Source-from-tarball gnome-shell recipe — the EIGHTEENTH real from-
## source production recipe to exercise the M9.H/I/K trio and the
## THIRD (closing) recipe in the GNOME stack batch (mutter / gdm /
## gnome-shell).
##
## Prior seventeen from-source recipes — fourteen meson (dbus-broker,
## libdrm, wayland, wlroots, sway, libxkbcommon, pixman, libinput,
## cairo, pango, gdk-pixbuf, glib2, mutter), one make (linux-kernel),
## one CMake (json-c), two autotools (expat + gdm) — collectively
## covered every M9.I flag-injection channel and every artifact-kind
## permutation. gnome-shell is the third meson recipe to ship BOTH a
## library AND an executable from the same ``package`` macro (Wayland
## was first with libwayland + waylandScanner, mutter was second with
## libMutter + mutterBin). The unique coverage angle for this third
## library+executable meson recipe is the kebab-to-camel package-
## identifier mapping (``gnome-shell`` -> ``gnomeShellSource``)
## combined with the library+executable artifact split: this is the
## first recipe to combine BOTH a multi-word-kebab package name AND a
## mixed-kind artifact set, exercising the M3 registry's name-mangling
## + per-package artifact partitioning at the same time.
##
## ## Why gnome-shell matters for the v1 desktop story
##
## gnome-shell is the GNOME user-session UI: the top bar, activities
## overview, window switcher, lock screen, notification daemon, and
## extension host. It links against mutter's ``libmutter-15.so`` for
## compositor glue and runs as the user's session leader after gdm
## hands off post-login. NDE-G1's ``gnome-session.service`` ``ExecStart``s
## ``gnome-shell --wayland`` directly. The standalone ``gnome-shell``
## binary is the executable artifact; ``libgnome-shell.so`` is the
## extension-host library third-party shell extensions link against.
##
## ## sha256 strategy
##
## We vendor the upstream 47.10 .tar.xz at
## ``recipes/packages/source/gnome-shell/vendor/gnome-shell-47.10.tar.xz``
## and reference it via a ``file://`` URL. The download.gnome.org
## release URL is recorded as ``sourceUrl`` in the ``versions:`` block
## for documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's
## emitted fetch action is offline-reproducible.
##
## ## Version choice — 47.10 (current upstream stable in the 47.x line)
##
## download.gnome.org publishes gnome-shell releases at
## ``https://download.gnome.org/sources/gnome-shell/`` and 47.10 is
## the current stable in the 47.x line as of mid-2026, matching the
## sibling ``mutterSource`` recipe's 47.10 pin. The 47.x ABI line
## consumes ``libmutter-15.so`` so the mutter/gnome-shell minor lines
## must stay in lockstep.
##
## sha256 = 5174d25bb05d35f3612498efc33a1de533fc4e0f39e3eb377fd09591c94a10e6
##  (computed locally over the vendored ``gnome-shell-47.10.tar.xz``,
##  2,144,616 bytes; downloaded once from the upstream URL recorded in
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
## records the artifacts via one ``library`` block + one
## ``executable`` block so the M9.K artifact registry already knows
## what shared object + binary to expect.
##
## ## Artifacts
##
## gnome-shell's meson build emits one shared library + one standalone
## binary:
##
##   * ``libgnome-shell.so`` — the extension-host library third-party
##                              gnome-shell extensions link against.
##   * ``gnome-shell`` — the standalone shell binary that drives the
##                       user session UI; NDE-G1's
##                       ``gnome-session.service`` invokes
##                       ``gnome-shell --wayland`` directly.
##
## We register the library under the package-level identifier
## ``libGnomeShell`` (camelCased from the hyphenated upstream SONAME
## per the gdk-pixbuf / glib2 precedent), and the executable under
## ``gnomeShell`` (camelCased from the hyphenated upstream binary
## name, also matching the gdk-pixbuf -> gdkPixbuf precedent; no
## ``Bin`` suffix is needed here because the package identifier is
## ``gnomeShellSource`` — distinct from the artifact identifier).
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``gtk_doc=false``        — skip the gtk-doc API documentation
##                                 build (heavy XSLT dep surface, not
##                                 needed at runtime).
##   * ``tests=false``          — skip the upstream test suite to keep
##                                 the build hermetic + fast.
##   * ``man=false``            — skip man-page generation.
##   * ``networkmanager=false`` — drop the NetworkManager status-menu
##                                 integration (NetworkManager is not
##                                 in the v1 NDE-G1 dep set; the
##                                 dummy-network shell variant
##                                 omits the menu entries).
##   * ``systemd=false``        — drop the systemd-journal + systemd-
##                                 user-unit-tracking integration
##                                 (NDE-G1's manifest layer drives
##                                 the systemd-user-session lifecycle
##                                 externally).
##   * ``extensions_app=false`` — skip the GNOME Extensions GUI app
##                                 (a separate ``gnome-extensions-app``
##                                 binary, not needed for the v1
##                                 minimal-shell variant).
##   * ``extensions_tool=false`` — skip the ``gnome-extensions`` CLI
##                                  tool (also not needed for the v1
##                                  minimal-shell variant).
##   * ``--buildtype=release``  — release-mode optimisation; matches
##                                 the sibling from-source recipes.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a developer variant that
## flips ``extensions_app=true`` for extension-development bundles).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package gnomeShellSource:
  ## From-source gnome-shell — eighteenth M9.H/I/K production recipe
  ## and the CLOSING recipe in the GNOME stack batch. Third meson
  ## recipe to ship a library + an executable from the same
  ## ``package`` macro, and the first recipe to combine a multi-word-
  ## kebab package name (``gnome-shell`` -> ``gnomeShellSource``)
  ## with a mixed-kind artifact set.
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
    ## project --- gnome-shell's canonical home.
    "47.10":
      sourceRevision = "47.10"
      sourceUrl = "https://download.gnome.org/sources/gnome-shell/47/gnome-shell-47.10.tar.xz"
      sourceRepository = "https://gitlab.gnome.org/GNOME/gnome-shell"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 2,144,616-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/gnome-shell/vendor/gnome-shell-47.10.tar.xz"
    sha256: "5174d25bb05d35f3612498efc33a1de533fc4e0f39e3eb377fd09591c94a10e6"
    extractStrip: 1

  nativeBuildDeps:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``. gnome-shell 47.x
    ## requires meson 1.3 for its modern GResource bundling.
    "meson >=1.3"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — gnome-shell is C11 with GJS
    ## (gjs-1.0) glue.
    "gcc >=11"

  buildDeps:
    ## glib2 is the foundation library gnome-shell consumes for the
    ## entire GObject hierarchy + GMainLoop + GSettings + GDBus.
    "glib2 >=2.62"
    ## mutter is the compositor library gnome-shell links against for
    ## its compositor glue; the sibling ``mutterSource`` recipe
    ## vendors 47.10 to match the gnome-shell 47.x ABI requirement.
    "mutter >=47"
    ## gjs is the GNOME JavaScript engine gnome-shell uses for its
    ## UI scripting layer (top bar, activities overview, extension
    ## host).
    "gjs >=1.78"
    ## libxkbcommon is the keyboard-keymap library gnome-shell's
    ## input handlers consume to handle layout switching / hotkey
    ## binding.
    "libxkbcommon >=1.5"
    ## cairo is the 2D drawing backend gnome-shell's UI compositor
    ## uses for on-screen overlay rendering.
    "cairo >=1.16"
    ## pango is the text-shaping + font-rendering library gnome-shell
    ## uses for top-bar labels / activities-overview text / lock-
    ## screen clock.
    "pango >=1.50"
    ## gdk-pixbuf is the image loader gnome-shell uses for icon
    ## decoding + wallpaper loading.
    "gdk-pixbuf >=2.40"

  mesonOptions:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: meson evaluates options
    ## left-to-right and the ``--buildtype=release`` sentinel lives at
    ## the tail so any override (e.g. a future debug-build variant)
    ## can append ``--buildtype=debug`` later without re-ordering this
    ## block.
    ##
    ## ``gtk_doc=false`` skips the gtk-doc API documentation build.
    ## ``tests=false`` skips the upstream test suite.
    ## ``man=false`` skips man-page generation.
    ## ``networkmanager=false`` drops the NetworkManager status-menu
    ## integration.
    ## ``systemd=false`` drops the systemd-journal integration.
    ## ``extensions_app=false`` skips the GNOME Extensions GUI app.
    ## ``extensions_tool=false`` skips the gnome-extensions CLI tool.
    "-Dgtk_doc=false"
    "-Dtests=false"
    "-Dman=false"
    "-Dnetworkmanager=false"
    "-Dsystemd=false"
    "-Dextensions_app=false"
    "-Dextensions_tool=false"
    "--buildtype=release"

  executable gnomeShell:
    ## ``/usr/bin/gnome-shell`` — the standalone shell binary that
    ## drives the user-session UI (top bar, activities overview,
    ## window switcher, lock screen, notification daemon, extension
    ## host). NDE-G1's ``gnome-session.service`` ``ExecStart``s
    ## ``gnome-shell --wayland`` directly. v1 records the artifact
    ## only; the per-artifact build body lands in M9.L when the
    ## convention's ninja-spawn + install-glue closes.
    discard

  library libGnomeShell:
    ## ``libgnome-shell.so`` — the extension-host library third-party
    ## gnome-shell extensions link against to register UI widgets /
    ## status-menu entries / activities-overview tiles. The
    ## hyphenated upstream SONAME is camelCased to ``libGnomeShell``
    ## per the gdk-pixbuf / glib2 precedent. v1 records the artifact
    ## only.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

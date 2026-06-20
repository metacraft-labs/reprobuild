## Source-from-tarball Sway recipe — the FIFTH real from-source
## production recipe to exercise the M9.H/I/K trio
## (fetch: + mesonOptions: + convention-layer fetch-action emission).
##
## Follows the dbus-broker (executables only), libdrm (libraries only),
## Wayland (mixed: 3 libs + 1 exe), and wlroots (single library)
## precedents: a meson/ninja build of upstream Sway fed by a vendored
## tarball whose sha256 is pinned here for deterministic offline test
## reproduction. Sway is the canonical i3-on-Wayland tiling compositor
## and the upstream-source side of the NDE-H1 desktop story; this
## recipe is the FINAL piece of the upstream Wayland stack
## (wayland-scanner → wayland libs → wlroots → SWAY).
##
## ## Why Sway matters for the NDE-H1 desktop story
##
## ``recipes/packages/desktop-environments/sway/repro.nim`` ships the
## NDE-H1 Sway compositor's user-facing glue (``/etc/sway/config``,
## ``sway-session.service``, ``/etc/wayland-sessions/sway.desktop``,
## ld.so.conf.d overlay). That recipe assumes the ``sway``,
## ``swaybar``, ``swaynag``, and ``swaymsg`` binaries already exist
## on PATH — in v1 they come from the (deferred) apt-jammy .deb. This
## recipe (``swaySource``) is the COMPLEMENT — it builds those four
## binaries from the upstream tarball via meson/ninja. The two recipes
## live at different paths so the NDE-H1 config-emission cache key is
## isolated from the upstream tarball sha256 (a 1.11 → 1.12 source
## bump invalidates only this recipe, not the unit-file emissions).
##
## ## Why this caps the Wayland-stack from-source chain
##
## Sway transitively consumes EVERY prior from-source Wayland recipe:
##
##   * ``wlrootsSource`` — Sway 1.11 hard-links against wlroots 0.19;
##     mismatched wlroots versions don't compile.
##   * ``waylandSource`` — libwayland-client / libwayland-server are
##     linked directly; ``wayland-scanner`` is invoked at build time
##     to emit protocol marshalling stubs for sway-protocols /
##     wlr-protocols XML files.
##   * (transitively via wlroots) ``libdrmSource`` for the DRM backend
##     and (would-be) Wayland for the protocol XML stubs the wlroots
##     scene-graph layer registers.
##
## With this recipe the wayland-stack from-source chain is COMPLETE —
## the M9.K convention layer can lower the whole stack
## (wayland-scanner → libwayland-{client,server,cursor} → libwlroots
## → sway/swaybar/swaynag/swaymsg) from declared ``fetch:`` +
## ``mesonOptions:`` blocks into a deterministic build graph once
## M9.L closes the ninja-spawn + install glue.
##
## ## sha256 strategy
##
## We vendor the upstream 1.11 source tarball at
## ``recipes/packages/source/sway/vendor/sway-1.11.tar.gz`` and
## reference it via a ``file://`` URL. The upstream GitHub release
## URL is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's
## emitted fetch action is offline-reproducible.
##
## ## Version choice — 1.11 (links wlroots 0.19)
##
## Sway 1.11 is the current upstream stable line and is the version
## that links against wlroots 0.19 (the version pinned in the sibling
## ``wlrootsSource`` recipe). The version pair is load-bearing — Sway
## upstream pins a specific wlroots stable line per release and won't
## compile against any other. A future bump to Sway 1.12 must move
## in lockstep with a wlroots 0.20 bump in ``wlrootsSource``.
##
## nixpkgs's ``pkgs/by-name/sw/sway-unwrapped/package.nix`` currently
## also pins 1.11 (consuming the GitHub archive tarball). The version
## cross-check holds; the sha256 cross-check does not because nixpkgs
## consumes ``fetchFromGitHub`` against the tag (which has a different
## hash than the ``/archive/refs/tags/<tag>.tar.gz`` URL we vendor —
## different upstream artifacts).
##
## sha256 = 034ec4519326d6af5275814700dde46e852c5174614109affe4c86b2fbee062a
##  (computed locally over the vendored ``sway-1.11.tar.gz``,
##  5,583,731 bytes; downloaded once from the upstream URL recorded in
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
##   4. install/output collection actions for the four executable
##      artifacts (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ninja-spawn + install glue lands in M9.L; the recipe
## records the executable artifacts via the ``executable`` block so
## the M9.K artifact registry already knows what binaries to expect.
##
## ## Executable artifacts
##
## Sway's meson build emits four binaries off the same configure /
## compile step:
##
##   * ``sway``     — the compositor itself; the long-running daemon
##                    that drives the wlroots backend, parses
##                    ``/etc/sway/config``, manages tiled workspaces,
##                    and routes input through libinput.
##   * ``swaybar``  — the status bar invoked from ``bar { ... }``
##                    blocks in the Sway config; consumes the
##                    i3bar-protocol JSON stream from a
##                    ``status_command``.
##   * ``swaynag``  — the modal-dialog notification helper Sway invokes
##                    for fatal-error confirmations (e.g. the "exit
##                    sway?" prompt bound to ``$mod+Shift+e``).
##   * ``swaymsg``  — the CLI control client that speaks Sway's IPC
##                    socket; used by user scripts, status bars, and
##                    Sway's own internal helpers to query workspace
##                    state and dispatch commands.
##
## All four ship as executables under the standard meson install
## prefix (``$prefix/bin/<name>``); there are no library artifacts.
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to a
## desktop-baseline set per the task brief:
##
##   * ``xwayland=disabled``  — drop XWayland support to keep the
##                              dependency surface small (matches the
##                              wlroots sibling's xwayland=disabled
##                              setting; NDE-H1 v1 is pure-Wayland).
##   * ``man-pages=disabled`` — skip the scdoc-based man-page build
##                              (heavy, runtime-irrelevant, and adds
##                              an extra build-time tool dep).
##   * ``tray=disabled``      — disable the libdbusmenu/systray support
##                              in swaybar (drops the libdbusmenu-gtk3
##                              dep, which would re-introduce GTK3 as
##                              a transitive runtime dep for a minimal
##                              compositor).
##   * ``werror=false``       — modern compilers add new warnings over
##                              time; ``-Werror`` makes the build
##                              version-fragile across toolchain bumps.
##   * ``--buildtype=release`` — release-mode optimisation; matches the
##                              dbus-broker / libdrm / Wayland / wlroots
##                              sibling recipes.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. an X11-enabled variant
## that flips xwayland back on, or a packaging variant that re-enables
## man-pages).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package swaySource:
  ## From-source Sway — fifth M9.H/I/K production recipe.
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``mesonOptions:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"meson"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags. Caps the upstream Wayland stack from-source
  ## chain (wayland-scanner → libwayland → wlroots → SWAY).

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical GitHub
    ## release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream GitHub project ---
    ## Sway's canonical home.
    "1.11":
      sourceRevision = "1.11"
      sourceUrl = "https://github.com/swaywm/sway/archive/refs/tags/1.11.tar.gz"
      sourceRepository = "https://github.com/swaywm/sway"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 5,583,731-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above. The vendored artifact is the GitHub
    ## ``/archive/refs/tags/<tag>.tar.gz`` URL; nixpkgs consumes the
    ## ``fetchFromGitHub`` form which has a different hash (different
    ## upstream artifact), so cross-checking sha256 against nixpkgs
    ## isn't possible. The version cross-check still holds — both
    ## nixpkgs (``pkgs/by-name/sw/sway-unwrapped/package.nix``) and
    ## this recipe pin 1.11 as the current upstream stable.
    url: "https://github.com/swaywm/sway/archive/refs/tags/1.11.tar.gz"
    sha256: "034ec4519326d6af5275814700dde46e852c5174614109affe4c86b2fbee062a"
    extractStrip: 1

  nativeBuildDeps:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``.
    "meson >=0.60"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — Sway is C11; 1.11 requires
    ## gcc 11+ for the same C11 atomics / TLS features wlroots uses.
    "gcc >=11"

  buildDeps:
    ## wlroots is the modular Wayland compositor library Sway links
    ## against for its backend / renderer / scene-graph / protocol
    ## implementations. 0.19 is the line Sway 1.11 pins; the sibling
    ## ``wlrootsSource`` recipe vendors 0.19.3 to match.
    "wlroots >=0.19"
    ## wayland-scanner is the protocol-XML → C marshalling-stub
    ## generator from the Wayland package; Sway's meson build invokes
    ## it during configure / compile to emit protocol stubs for
    ## sway-protocols + wlr-protocols XML files. Recipe name
    ## ``wayland`` matches the sibling source recipe — the scanner is
    ## a sub-artefact of the wayland tarball, not a separate package.
    "wayland"
    ## libxkbcommon is the keyboard-keymap library Sway's seat / input
    ## layer consumes to translate raw evdev keycodes into XKB
    ## keysyms (e.g. parsing ``bindsym Mod4+Return exec foot`` from
    ## ``/etc/sway/config``).
    "libxkbcommon >=1.5"
    ## pcre2 is the regex engine Sway uses for criteria-matching in
    ## ``for_window [class=...] ...`` rules and the IPC ``GET_TREE``
    ## query language.
    "pcre2"
    ## json-c is the JSON serialiser Sway uses for its IPC socket
    ## protocol (the wire format swaymsg + status bars consume) and
    ## for parsing i3bar-protocol input.
    "json-c"
    ## pango is the text-shaping + font-rendering library swaybar +
    ## swaynag use to draw labels with proper kerning / fallback
    ## fonts / right-to-left support.
    "pango"
    ## cairo is the 2D drawing backend pango renders into for swaybar +
    ## swaynag; also used directly for drawing block backgrounds /
    ## separators.
    "cairo"
    ## gdk-pixbuf is the image loader swaybar uses for icon tray
    ## entries (when tray=enabled — disabled here, but the
    ## dependency declaration stays explicit for forward compat) and
    ## for ``output background <image>`` config entries.
    "gdk-pixbuf >=2.40"

  config:
    ## No prefix lifted from `mesonOptions:`; flags inlined in the `build:` block.
    discard
  executable sway:
    ## ``/usr/bin/sway`` — the compositor itself; long-running daemon
    ## that drives the wlroots backend, parses ``/etc/sway/config``,
    ## manages tiled workspaces, and routes input through libinput.
    ## The NDE-H1 ``sway-session.service`` ``ExecStart`` invokes this
    ## binary directly.
    ## v1 records the artifact only; the per-artifact build body lands
    ## in M9.L when the convention's ninja-spawn + install-glue closes.
    discard

  executable swaybar:
    ## ``/usr/bin/swaybar`` — the status bar invoked from
    ## ``bar { ... }`` blocks in ``/etc/sway/config``; consumes the
    ## i3bar-protocol JSON stream from a ``status_command``.
    discard

  executable swaynag:
    ## ``/usr/bin/swaynag`` — modal-dialog notification helper Sway
    ## invokes for fatal-error confirmations (e.g. the "exit sway?"
    ## prompt bound to ``$mod+Shift+e`` in the default config).
    discard

  executable swaymsg:
    ## ``/usr/bin/swaymsg`` — CLI control client that speaks Sway's IPC
    ## socket; used by user scripts, status bars, and Sway's own
    ## internal helpers to query workspace state and dispatch
    ## commands.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `meson_package(...)` constructor.
    setCurrentOwningPackageOverride("swaySource")
    try:
      let opts = @[
        "-Dxwayland=disabled",
        "-Dman-pages=disabled",
        "-Dtray=disabled",
        "-Dwerror=false",
        "--buildtype=release",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("sway")
      discard pkg.executable("swaybar")
      discard pkg.executable("swaynag")
      discard pkg.executable("swaymsg")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

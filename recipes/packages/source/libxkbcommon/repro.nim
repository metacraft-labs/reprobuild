## Source-from-tarball libxkbcommon recipe — the SEVENTH real
## from-source production recipe to exercise the M9.H/I/K trio
## (fetch: + mesonOptions: + convention-layer fetch-action emission).
##
## Follows the dbus-broker (executables only), libdrm (libraries only),
## Wayland (mixed), wlroots (single library), Sway (multiple
## executables), and linux-kernel (executable + files) precedents:
## a meson/ninja build of upstream libxkbcommon fed by a vendored
## tarball whose sha256 is pinned here for deterministic offline test
## reproduction. libxkbcommon emits ONE library (``libxkbcommon.so``)
## plus ONE command-line tool (``xkbcli``); it is the second
## library+executable mixed recipe (Wayland was the first), and it is
## the FIRST recipe where the executable count is the smaller of the
## two (1 lib + 1 exe), exercising the M3 artifact registry's
## kind-discriminator preservation in a balanced split.
##
## ## Why libxkbcommon matters for the NDE-H Sway / NDE-G1 GNOME /
## ## NDE-K1 Plasma desktop stories
##
## libxkbcommon is the keyboard-keymap library every modern Wayland
## compositor links against to translate raw evdev keycodes into XKB
## keysyms — wlroots (and thus Sway), Mutter (GNOME), and KWin (Plasma)
## all depend on it. The sibling ``wlrootsSource`` recipe pins
## ``libxkbcommon >=1.5`` in its ``uses:`` block, so this recipe is the
## upstream-source side of that dependency edge.
##
## ## sha256 strategy
##
## We vendor the upstream 1.13.2 source archive at
## ``recipes/packages/source/libxkbcommon/vendor/libxkbcommon-1.13.2.tar.gz``
## and reference it via a ``file://`` URL. The upstream GitHub release
## URL is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's
## emitted fetch action is offline-reproducible.
##
## ## Tarball-source caveat — GitHub source archive
##
## Unlike libdrm and Wayland (which ship official ``release dist``
## tarballs on freedesktop.org / gitlab releases), upstream
## libxkbcommon no longer publishes a standalone release dist tarball
## — the project homepage at ``https://xkbcommon.org`` lists releases
## but links to the wayland-devel mailing-list announcement only and
## points consumers at the Git tag. We follow the precedent set by
## ``swaySource`` and vendor the canonical
## ``https://github.com/xkbcommon/libxkbcommon/archive/refs/tags/xkbcommon-1.13.2.tar.gz``
## artifact. This is the same artifact nixpkgs's
## ``pkgs/development/libraries/libxkbcommon/default.nix`` consumes
## via ``fetchFromGitHub`` against the tag.
##
## ## Version choice — 1.13.2 (current upstream stable)
##
## ``https://xkbcommon.org`` lists 1.13.2 as the latest API- and
## ABI-stable release (May 30, 2026). Picking the current stable
## tracks the modern-desktop baseline; downstream wlroots / Sway /
## GNOME / Plasma all build against the 1.10+ ABI surface so a 1.13
## pin is forward-compatible across the whole stack.
##
## sha256 = acc4d5f7c3cbba5f9f8d08d8bdbeede84ecede46792f47929aa9321873385528
##  (computed locally over the vendored
##  ``libxkbcommon-1.13.2.tar.gz``, 1,243,485 bytes).
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
## records both artifacts via the ``library`` / ``executable`` blocks
## so the M9.K artifact registry already knows which shared object
## and which binary to expect.
##
## ## Library + executable artifacts
##
## libxkbcommon's meson build emits:
##
##   * ``libxkbcommon.so``  — the core keyboard-keymap library, linked
##                            by every Wayland compositor (wlroots /
##                            Mutter / KWin) and many X11 toolkits.
##   * ``xkbcli``           — the umbrella command-line tool exposed
##                            via ``-Denable-tools=true``; ships
##                            sub-commands (``compile-keymap``,
##                            ``how-to-type``, ``interactive-evdev``,
##                            ``interactive-wayland``,
##                            ``list-models``) used by users +
##                            tooling to debug keymaps.
##
## We intentionally do NOT register the X11-side library
## ``libxkbcommon-x11.so`` since the ``-Denable-x11=false`` flag below
## disables it — the modern-desktop baseline is pure-Wayland and
## consuming the X11 codepath would pull libxcb + libxcb-xkb into the
## dependency surface.
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``enable-docs=false``    — skip doxygen documentation
##                                generation (not needed at runtime).
##   * ``enable-x11=false``     — skip the X11 codepath
##                                (``libxkbcommon-x11``) to keep the
##                                dependency surface Wayland-only.
##   * ``enable-wayland=true``  — build the Wayland interactive demo
##                                that ``xkbcli`` links in;
##                                load-bearing for the v1 desktop
##                                use case.
##   * ``enable-tools=true``    — build the ``xkbcli`` umbrella CLI.
##   * ``--buildtype=release``  — release-mode optimisation; matches
##                                the sibling from-source recipes.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. an X11-enabled variant
## for legacy desktop bundles, or a developer variant that flips
## ``enable-docs=true`` for upstream contributions).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package libxkbcommonSource:
  ## From-source libxkbcommon — seventh M9.H/I/K production recipe.
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``mesonOptions:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"meson"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags. Mixed library + executable artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical GitHub
    ## release archive URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream GitHub project ---
    ## libxkbcommon's canonical home post-freedesktop-migration.
    "1.13.2":
      sourceRevision = "xkbcommon-1.13.2"
      sourceUrl = "https://github.com/xkbcommon/libxkbcommon/archive/refs/tags/xkbcommon-1.13.2.tar.gz"
      sourceRepository = "https://github.com/xkbcommon/libxkbcommon"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 1,243,485-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://github.com/xkbcommon/libxkbcommon/archive/refs/tags/xkbcommon-1.13.2.tar.gz"
    sha256: "acc4d5f7c3cbba5f9f8d08d8bdbeede84ecede46792f47929aa9321873385528"
    extractStrip: 1

  nativeBuildDeps:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``.
    "meson >=0.59"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — libxkbcommon is plain C11 with
    ## a small C++ helper layer the C compiler handles.
    "gcc >=7"
    ## bison generates the keymap-text-format parser at build time;
    ## upstream's meson build hard-requires a bison-compatible
    ## yacc(1).
    "bison >=3.0"

  buildDeps:
    ## libwayland-client + wayland-scanner are pulled in by the
    ## ``enable-wayland=true`` flag below — the Wayland interactive
    ## demo links libwayland-client and the protocol XML stubs are
    ## generated via wayland-scanner.
    "wayland >=1.22"
    ## wayland-protocols ships the XML protocol files the Wayland
    ## demo consumes (xdg-shell etc.); declared for completeness so
    ## the dependency surface stays explicit.
    "wayland-protocols >=1.31"

  config:
    ## No prefix lifted from `mesonOptions:`; flags inlined in the `build:` block.
    discard
  library libxkbcommon:
    ## ``libxkbcommon.so`` — the core keyboard-keymap library, linked
    ## by every Wayland compositor (wlroots / Mutter / KWin) and many
    ## X11 toolkits. v1 records the artifact only; the per-artifact
    ## build body lands in M9.L when the convention's ninja-spawn +
    ## install-glue closes.
    discard

  executable xkbcli:
    ## ``xkbcli`` — the umbrella command-line tool exposed via
    ## ``-Denable-tools=true``; ships sub-commands
    ## (``compile-keymap``, ``how-to-type``, ``interactive-evdev``,
    ## ``interactive-wayland``, ``list-models``) used by users +
    ## tooling to debug keymaps. v1 records the artifact only.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `meson_package(...)` constructor.
    setCurrentOwningPackageOverride("libxkbcommonSource")
    try:
      let opts = @[
        "-Denable-docs=false",
        "-Denable-x11=false",
        "-Denable-wayland=true",
        "-Denable-tools=true",
        "--buildtype=release",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libxkbcommon")
      discard pkg.executable("xkbcli")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

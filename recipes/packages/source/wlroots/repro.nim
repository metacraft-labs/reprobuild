## Source-from-tarball wlroots recipe — the FOURTH real from-source
## production recipe to exercise the M9.H/I/K trio
## (fetch: + mesonOptions: + convention-layer fetch-action emission).
##
## Follows the dbus-broker (executables only), libdrm (libraries only),
## and Wayland (mixed) precedents: a meson/ninja build of upstream
## wlroots fed by a vendored tarball whose sha256 is pinned here for
## deterministic offline test reproduction. wlroots is a single
## shared-library output (``libwlroots.so``) — the modular Wayland
## compositor library that Sway, labwc, and roughly every wlroots-based
## Wayland compositor in the ecosystem link against.
##
## ## Why wlroots matters for the NDE-H Sway desktop story
##
## ``recipes/packages/desktop-environments/sway/repro.nim`` ships the
## NDE-H Sway compositor's user-facing glue. Sway is wlroots' canonical
## upstream consumer — upstream Sway versions pin a specific wlroots
## stable line (0.18 / 0.19 / 0.20) and won't compile against any
## other. This recipe is the upstream-source side of that pairing.
## The wlroots library exposes the backend (DRM/KMS, libinput, X11),
## renderer (GLES2/Vulkan), scene graph, and protocol implementations
## that every wlroots-based compositor needs; without this recipe the
## NDE-H story has a dangling wlroots dependency.
##
## ## sha256 strategy
##
## We vendor the upstream 0.19.3 .tar.gz at
## ``recipes/packages/source/wlroots/vendor/wlroots-0.19.3.tar.gz`` and
## reference it via a ``file://`` URL. The upstream gitlab releases
## URL is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's
## emitted fetch action is offline-reproducible.
##
## ## Version choice — 0.19.3 (= nixpkgs ``wlroots_0_19``)
##
## wlroots ships multiple parallel stable lines; nixpkgs currently
## pins both ``wlroots_0_19 = 0.19.3`` and ``wlroots_0_20 = 0.20.1``
## at ``pkgs/development/libraries/wlroots/default.nix``. We follow
## the 0.19 line because that's the version upstream Sway 1.11.x
## links against — picking 0.20 would orphan the NDE-H Sway recipe
## downstream. A future bump can flip to 0.20 in lockstep with the
## Sway pin once upstream Sway moves.
##
## ## Tarball-source caveat — release dist vs git archive
##
## Unlike nixpkgs (which uses ``fetchFromGitLab`` against the tag),
## we follow the task brief and vendor the official release dist
## tarball published under
## ``https://gitlab.freedesktop.org/wlroots/wlroots/-/releases/0.19.3/downloads/wlroots-0.19.3.tar.gz``.
## The dist tarball and the GitLab-generated git-archive have
## different sha256 hashes — the dist tarball is the canonical
## upstream-published artifact and is what packaging ecosystems
## outside Nix consume. nixpkgs's ``sha256-J+wSVUtuizaCyCn523chFbE8VtbPjyu5XYv5eLT+GM0=``
## therefore CANNOT be byte-cross-checked against our vendored copy
## (different upstream artifact); the version cross-check still
## holds (both pin 0.19.3 as the latest 0.19 stable).
##
## sha256 = 5d02693175e5afd9af5f10e3e4976d6e9249dc39a90eb17d23fa5f54b125ccc5
##  (computed locally over the vendored ``wlroots-0.19.3.tar.gz``,
##  671,529 bytes; downloaded once from the upstream URL recorded in
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
##   4. install/output collection actions for the library artifact
##      (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ninja-spawn + install glue lands in M9.L; the recipe
## records the library artifact via the ``library`` block so the
## M9.K artifact registry already knows what shared object to expect.
##
## ## Library artifact
##
## wlroots produces a single shared library — ``libwlroots.so`` — that
## bundles the backend, renderer, scene graph, and protocol
## implementations. Unlike libdrm (which splits the per-vendor side
## libraries) or Wayland (which splits client/server/cursor), wlroots'
## meson build keeps everything in one .so. The per-backend / per-API
## toggles are flipped via mesonOptions below rather than producing
## separate artifacts.
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to a
## desktop-baseline set per the task brief:
##
##   * ``examples=false``       — skip the upstream example
##                                 compositors (TinyWL et al); they
##                                 are not consumed by Sway / labwc
##                                 and would bloat the build.
##   * ``xwayland=disabled``    — disable XWayland support to keep
##                                 the dependency surface small (the
##                                 X11 server is a heavy transitive
##                                 dep that NDE-H Sway does not need
##                                 in its v1 hermetic shape).
##   * ``xcb-errors=disabled``  — companion to the XWayland-off
##                                 setting; xcb-errors is only used
##                                 by the XWayland codepath.
##   * ``werror=false``         — modern compilers add new warnings
##                                 over time; ``-Werror`` makes the
##                                 build version-fragile across
##                                 toolchain bumps.
##   * ``--buildtype=release``  — release-mode optimisation; matches
##                                 the dbus-broker / libdrm / Wayland
##                                 sibling recipes.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. an X11-enabled variant
## that flips XWayland back on, or a developer variant that enables
## examples + Werror for upstream testing).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package wlrootsSource:
  ## From-source wlroots — fourth M9.H/I/K production recipe.
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``mesonOptions:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"meson"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## freedesktop.org gitlab release tarball URL so a future
    ## maintainer running ``repro update-source`` can re-fetch from
    ## upstream; the live ``fetch:`` block below points at the
    ## vendored copy for deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream gitlab project ---
    ## wlroots' canonical home.
    "0.19.3":
      sourceRevision = "0.19.3"
      sourceUrl = "https://gitlab.freedesktop.org/wlroots/wlroots/-/releases/0.19.3/downloads/wlroots-0.19.3.tar.gz"
      sourceRepository = "https://gitlab.freedesktop.org/wlroots/wlroots"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 671,529-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above. The vendored artifact is the official
    ## upstream release dist tarball (NOT a git-archive); nixpkgs
    ## consumes the git-archive instead, so cross-checking sha256
    ## against nixpkgs isn't possible. The version cross-check still
    ## holds — both nixpkgs and this recipe pin 0.19.3 as the current
    ## 0.19 stable.
    url: "file:///metacraft/reprobuild/recipes/packages/source/wlroots/vendor/wlroots-0.19.3.tar.gz"
    sha256: "5d02693175e5afd9af5f10e3e4976d6e9249dc39a90eb17d23fa5f54b125ccc5"
    extractStrip: 1

  nativeBuildDeps:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``.
    "meson >=0.59"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — wlroots is C11; 0.19 requires
    ## gcc 11+ for atomics + C11 thread-local storage portability.
    "gcc >=11"

  buildDeps:
    ## libdrm is the user-space DRM ioctl wrapper that wlroots' DRM
    ## backend invokes for KMS mode-setting / page-flip / GBM
    ## allocation. 2.4.122 matches wlroots 0.19's documented minimum.
    "libdrm >=2.4.122"
    ## wayland (= libwayland-client + libwayland-server) is the
    ## protocol library every wlroots compositor consumes for its
    ## server-side endpoints.
    "wayland >=1.22"
    ## wayland-scanner is the protocol-XML → C marshalling-stub
    ## generator from the Wayland package; wlroots' meson build
    ## invokes it during configure / compile to emit protocol stubs.
    "wayland-scanner"
    ## libxkbcommon is the keyboard-keymap library wlroots' seat /
    ## input layer consumes to translate raw evdev keycodes into
    ## XKB keysyms.
    "libxkbcommon >=1.5"
    ## pixman is the 2D pixel-manipulation library used by wlroots'
    ## software renderer + scene-graph damage tracking.
    "pixman >=0.42"
    ## libinput is the input-device abstraction library wlroots'
    ## libinput backend wraps for evdev / touchpad / tablet support.
    "libinput >=1.14"

  mesonOptions:
    ## Flag set mirroring the task brief's desktop-baseline. Order is
    ## load-bearing: meson evaluates options left-to-right and the
    ## ``--buildtype=release`` sentinel lives at the tail so any
    ## override (e.g. a future debug-build variant) can append
    ## ``--buildtype=debug`` later without re-ordering this block.
    ##
    ## ``examples=false`` skips the example compositors (TinyWL et al)
    ## which Sway / labwc don't consume.
    ## ``xwayland=disabled`` drops the X11-server transitive dep
    ## (large tree; NDE-H Sway v1 is pure-Wayland).
    ## ``xcb-errors=disabled`` companion to the XWayland-off setting.
    ## ``werror=false`` makes the build resilient to toolchain bumps.
    "-Dexamples=false"
    "-Dxwayland=disabled"
    "-Dxcb-errors=disabled"
    "-Dwerror=false"
    "--buildtype=release"

  library libwlroots:
    ## ``libwlroots.so`` — the modular Wayland compositor library;
    ## wlroots ships everything (backend + renderer + scene + protocol
    ## implementations) in a single shared object. NDE-H Sway,
    ## labwc, and effectively every wlroots-based compositor links
    ## against this single .so.
    ## v1 records the artifact only; the per-artifact build body lands
    ## in M9.L when the convention's ninja-spawn + install-glue closes.
    discard

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

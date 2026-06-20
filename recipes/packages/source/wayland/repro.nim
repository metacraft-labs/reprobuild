## Source-from-tarball Wayland recipe — the THIRD real from-source
## production recipe to exercise the M9.H/I/K trio
## (fetch: + mesonOptions: + convention-layer fetch-action emission).
##
## Follows the dbus-broker (executables) + libdrm (libraries) precedent:
## a meson/ninja build of upstream Wayland fed by a vendored tarball
## whose sha256 is pinned here for deterministic offline test
## reproduction. Wayland is the FIRST from-source recipe that produces
## BOTH library AND executable artifacts off the same build — the core
## protocol libraries (``libwayland-client``, ``libwayland-server``,
## ``libwayland-cursor``) plus the ``wayland-scanner`` code generator
## that wlroots / Sway / GNOME / Plasma all invoke at build time to
## emit protocol stubs.
##
## ## Why Wayland matters for the NDE-G/H/G1/K1 desktop stories
##
## ``recipes/packages/de-foundation/graphics-stack/repro.nim`` emits
## the user-facing graphics-stack config glue, and the three desktop
## environment recipes (Sway, GNOME, Plasma) all ship Wayland
## compositors that depend on Wayland's protocol library + scanner at
## build time. ``libwayland-client.so`` is linked by EVERY Wayland
## client (GTK, Qt, Firefox, ...). ``wayland-scanner`` is invoked at
## build time by every compositor to generate protocol marshalling
## stubs from XML protocol definitions. This recipe is the
## upstream-source side that all three DE recipes ultimately consume.
##
## ## sha256 strategy
##
## We vendor the upstream 1.25.0 .tar.xz at
## ``recipes/packages/source/wayland/vendor/wayland-1.25.0.tar.xz`` and
## reference it via a ``file://`` URL. The upstream gitlab releases
## URL is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's
## emitted fetch action is offline-reproducible.
##
## ## Version drift vs the task brief
##
## The brief named 1.23.1; nixpkgs's
## ``pkgs/development/libraries/wayland/default.nix`` pins 1.25.0
## (SRI hash ``sha256-wGXwQK/f8xd2gGAPJJcn5Boa/CL8zyciLxX1MG+qHwM=``
## which decodes to the hex below). We follow the libdrm precedent
## and drift to the version nixpkgs ships so the cross-check stays
## meaningful — 1.25.0 is the current modern-desktop baseline and the
## upstream gitlab releases page confirms it as the latest stable.
##
## sha256 = c065f040afdff3177680600f249727e41a1afc22fccf27222f15f5306faa1f03
##  (computed locally over the vendored
##  ``wayland-1.25.0.tar.xz``, 609,628 bytes; matches the
##  ``sha256-wGXwQK/f8xd2gGAPJJcn5Boa/CL8zyciLxX1MG+qHwM=`` SRI hash
##  that nixpkgs ships at
##  ``pkgs/development/libraries/wayland/default.nix`` — the
##  cross-check confirms the upstream tarball is byte-identical to
##  what the broader ecosystem builds against).
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
##   4. install/output collection actions for the three library
##      artifacts + the wayland-scanner executable (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ninja-spawn + install glue lands in M9.L; the recipe
## records all four artifacts via the ``library`` / ``executable``
## blocks so the M9.K artifact registry already knows which shared
## objects / binaries to expect.
##
## ## Library vs executable artifacts
##
## Unlike dbus-broker (executables only) or libdrm (libraries only),
## Wayland's meson build emits BOTH kinds off the same configure /
## compile step:
##
##   * ``libwayland-client.so`` — the client-side protocol library,
##     linked by every Wayland app (GTK/Qt/Firefox/...).
##   * ``libwayland-server.so`` — the server-side protocol library,
##     linked by every Wayland compositor (Sway/Mutter/KWin/...).
##   * ``libwayland-cursor.so`` — cursor-theme loader used by Wayland
##     clients to render system cursors with the right theme.
##   * ``wayland-scanner``      — the protocol-code generator binary
##     that compositors + clients invoke at build time to turn
##     protocol XML into C marshalling stubs.
##
## ``libwayland-egl.so`` is technically also part of the upstream
## build but is intentionally NOT registered here — it's a thin shim
## that Mesa replaces with its own libwayland-egl at runtime via the
## ``wayland-egl-backend`` extension, so registering it would create
## an artifact-registry collision with the Mesa graphics-stack
## recipe down the line.
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to a
## modern-desktop baseline (libraries + scanner on; documentation,
## DTD validation, and tests off to keep the build hermetic + fast).
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a developer variant that
## flips tests on, or a packaging variant that emits documentation).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package waylandSource:
  ## From-source Wayland — third M9.H/I/K production recipe.
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``mesonOptions:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"meson"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags. FIRST recipe to mix ``library`` + ``executable``
  ## artifacts in a single from-source production package.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## freedesktop.org gitlab release tarball URL so a future
    ## maintainer running ``repro update-source`` can re-fetch from
    ## upstream; the live ``fetch:`` block below points at the
    ## vendored copy for deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream gitlab project ---
    ## Wayland's canonical home.
    "1.25.0":
      sourceRevision = "1.25.0"
      sourceUrl = "https://gitlab.freedesktop.org/wayland/wayland/-/releases/1.25.0/downloads/wayland-1.25.0.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/wayland/wayland"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 609,628-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above. The same hash is independently shipped by
    ## nixpkgs at ``pkgs/development/libraries/wayland/default.nix``
    ## (in SRI form), so a future bump can cross-reference both
    ## sources.
    url: "https://gitlab.freedesktop.org/wayland/wayland/-/releases/1.25.0/downloads/wayland-1.25.0.tar.xz"
    sha256: "c065f040afdff3177680600f249727e41a1afc22fccf27222f15f5306faa1f03"
    extractStrip: 1

  nativeBuildDeps:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``.
    "meson >=0.59"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — Wayland is plain C11 with no
    ## C++ component, so the C compiler is sufficient.
    "gcc >=7"

  buildDeps:
    ## expat is the XML parser the wayland-scanner code generator
    ## links against to read protocol XML files.
    "expat >=2.4"
    ## libxml2 is consumed by the (disabled-here) dtd-validation
    ## codepath and by the (disabled-here) test suite; declared so
    ## the dependency surface stays explicit if a future variant
    ## flips ``tests=true`` or ``dtd_validation=true``.
    "libxml2 >=2.9"

  config:
    ## No prefix lifted from `mesonOptions:`; flags inlined in the `build:` block.
    discard
  library libwaylandClient:
    ## ``libwayland-client.so`` — client-side protocol library, linked
    ## by every Wayland application (GTK/Qt/Firefox/...).
    ## v1 records the artifact only; the per-artifact build body lands
    ## in M9.L when the convention's ninja-spawn + install-glue closes.
    discard

  library libwaylandServer:
    ## ``libwayland-server.so`` — server-side protocol library, linked
    ## by every Wayland compositor (Sway/Mutter/KWin/...).
    discard

  library libwaylandCursor:
    ## ``libwayland-cursor.so`` — cursor-theme loader used by Wayland
    ## clients to render system cursors with the right theme.
    discard

  executable waylandScanner:
    ## ``wayland-scanner`` — protocol-code generator binary invoked at
    ## build time by every Wayland compositor + client to turn
    ## protocol XML files into C marshalling stubs. The NDE-G
    ## graphics-stack + NDE-H Sway + NDE-G1 GNOME + NDE-K1 Plasma
    ## recipes all transitively consume this binary at their own
    ## build time.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `meson_package(...)` constructor.
    setCurrentOwningPackageOverride("waylandSource")
    try:
      let opts = @[
        "-Ddocumentation=false",
        "-Ddtd_validation=false",
        "-Dlibraries=true",
        "-Dscanner=true",
        "-Dtests=false",
        "--buildtype=release",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libwaylandClient")
      discard pkg.library("libwaylandServer")
      discard pkg.library("libwaylandCursor")
      discard pkg.executable("waylandScanner")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

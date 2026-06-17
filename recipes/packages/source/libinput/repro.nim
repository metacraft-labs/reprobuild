## Source-from-tarball libinput recipe — the NINTH real from-source
## production recipe to exercise the M9.H/I/K trio
## (fetch: + mesonOptions: + convention-layer fetch-action emission).
##
## Follows the dbus-broker (executables only), libdrm (libraries only),
## Wayland (mixed), wlroots (single library), Sway (multiple
## executables), linux-kernel (executable + files), libxkbcommon
## (balanced 1+1), and pixman (single library) precedents: a
## meson/ninja build of upstream libinput fed by a vendored tarball
## whose sha256 is pinned here for deterministic offline test
## reproduction. libinput's coverage angle vs the prior eight is a
## library + executable mix where BOTH artifacts SHARE the same name
## token (``libinput.so`` vs the ``libinput`` CLI binary) — the M3
## artifact registry must keep them disambiguated via the
## ``dakLibrary`` / ``dakExecutable`` kind discriminator AND via
## distinct artifact identifiers in the package's declaration body.
##
## ## Library / executable name collision — design note
##
## Upstream libinput's meson build emits:
##
##   * ``libinput.so``  — the input-device abstraction shared library.
##   * ``libinput``     — the diagnostic command-line tool (yes, the
##                        binary has the same name as the library; it
##                        ships sub-commands ``list-devices``,
##                        ``debug-events``, ``debug-gui``,
##                        ``measure``, ``record``, ``replay``, ...).
##
## Within the DSL we register them under DISTINCT Nim-identifier
## artifact names — ``libinput`` for the shared library (matches the
## ``.so`` token) and ``libinputBin`` for the executable (suffixed
## to avoid the macro-level Nim identifier collision). The M9.L
## install glue will resolve them to the correct on-disk filenames
## (``$prefix/lib/libinput.so.*`` and ``$prefix/bin/libinput``).
##
## ## Why libinput matters for the NDE-H Sway / NDE-G1 GNOME / NDE-K1
## ## Plasma desktop stories
##
## libinput is the input-device abstraction layer every modern
## Wayland compositor links against to consume evdev events with
## consistent palm-rejection, gesture, and pointer-acceleration
## semantics. The sibling ``wlrootsSource`` recipe pins
## ``libinput >=1.14`` in its ``uses:`` block, so this recipe is the
## upstream-source side of that dependency edge. Mutter (GNOME) and
## KWin (Plasma) also link against libinput.
##
## ## sha256 strategy
##
## We vendor the upstream 1.28.1 source tarball at
## ``recipes/packages/source/libinput/vendor/libinput-1.28.1.tar.gz``
## and reference it via a ``file://`` URL. The Debian source archive
## URL is recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's
## emitted fetch action is offline-reproducible.
##
## ## Tarball-source caveat — Debian mirror vs gitlab releases
##
## The canonical upstream URL at
## ``https://gitlab.freedesktop.org/libinput/libinput/-/releases/<ver>/downloads/libinput-<ver>.tar.xz``
## currently sits behind a freedesktop.org Anubis bot-protection
## challenge that defeats non-interactive HTTP clients. We follow the
## "If a release URL fails, try archive.org or pkgs.org for the same
## version" branch of the task brief and vendor the equivalent
## artifact from Debian's source pool at
## ``http://deb.debian.org/debian/pool/main/libi/libinput/libinput_1.28.1.orig.tar.gz``.
## The Debian ``orig.tar.gz`` is the canonical upstream-published
## artifact (Debian's policy mandates byte-identical upstream tarballs
## under that filename); only the wrapper compression differs from
## the Anubis-gated freedesktop.org ``.tar.xz``.
##
## ## Version choice — 1.28.1 (Debian's current stable)
##
## libinput's upstream ship cadence is approximately one feature
## release per quarter; 1.28.1 is the Debian current-stable point in
## the 1.28 line. nixpkgs's
## ``pkgs/development/libraries/libinput/default.nix`` and Arch's
## ``libinput`` package both ship newer versions
## (1.29 / 1.31 respectively), but the wlroots 0.19 + Sway 1.11
## consumer pair pinned in the sibling recipes only needs
## ``libinput >=1.14``, so 1.28.1 is safely forward-compatible.
##
## sha256 = a13f8c9a7d93df3c85c66afd135f0296701d8d32f911991b7aa4273fdd6a42a3
##  (computed locally over the vendored ``libinput-1.28.1.tar.gz``,
##  1,074,349 bytes; downloaded once from the Debian source pool URL
##  recorded in ``versions:`` above).
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
## so the M9.K artifact registry already knows what shared object
## and what binary to expect.
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``documentation=false`` — skip doxygen / sphinx documentation
##                               (not needed at runtime).
##   * ``debug-gui=false``     — skip the GTK-based event-debug GUI
##                               (drops a heavy gtk4 dep that no v1
##                               desktop story needs).
##   * ``tests=false``         — skip the upstream test suite (matches
##                               the other from-source siblings).
##   * ``libwacom=false``      — skip wacom-tablet integration to keep
##                               the dependency surface small (no v1
##                               desktop story exercises tablets).
##   * ``udev-dir=/lib/udev``  — install udev rules under the LSB
##                               canonical ``/lib/udev`` path so
##                               distro udev daemons pick them up.
##   * ``--buildtype=release`` — release-mode optimisation; matches
##                               the sibling from-source recipes.
##
## Downstream configuration knobs would live here when the per-distro
## variants need different strategies (e.g. a tablet-focused variant
## that flips ``libwacom=true``).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package libinputSource:
  ## From-source libinput — ninth M9.H/I/K production recipe.
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``mesonOptions:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"meson"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags. Library + executable name-collision recipe.

  defaultToolProvisioning "path"

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the Debian source
    ## pool URL so a future maintainer running ``repro update-source``
    ## can re-fetch from the same source; the live ``fetch:`` block
    ## below points at the vendored copy for deterministic offline
    ## test reproduction.
    ##
    ## ``sourceRepository`` points at the upstream freedesktop.org
    ## gitlab project --- libinput's canonical home.
    "1.28.1":
      sourceRevision = "1.28.1"
      sourceUrl = "http://deb.debian.org/debian/pool/main/libi/libinput/libinput_1.28.1.orig.tar.gz"
      sourceRepository = "https://gitlab.freedesktop.org/libinput/libinput"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 1,074,349-byte tarball
    ## downloaded once from the Debian source pool URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/libinput/vendor/libinput-1.28.1.tar.gz"
    sha256: "a13f8c9a7d93df3c85c66afd135f0296701d8d32f911991b7aa4273fdd6a42a3"
    extractStrip: 1

  uses:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``.
    "meson >=0.59"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — libinput is plain C99 with a
    ## modern compiler-flag surface.
    "gcc >=7"
    ## libudev is the userspace device-management library libinput's
    ## evdev backend wraps for hot-plug event delivery.
    "libudev >=232"
    ## libmtdev is the multitouch-protocol-translation library
    ## libinput consumes for non-mtdev kernels and trackpad mt-A
    ## drivers.
    "mtdev >=1.1"
    ## libevdev is the userspace evdev event-handling library —
    ## libinput's input layer's primary consumer.
    "libevdev >=1.9"

  mesonOptions:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: meson evaluates options
    ## left-to-right and the ``--buildtype=release`` sentinel lives at
    ## the tail so any override (e.g. a future debug-build variant)
    ## can append ``--buildtype=debug`` later without re-ordering this
    ## block.
    ##
    ## ``documentation=false`` skips doxygen + sphinx documentation
    ## generation.
    ## ``debug-gui=false`` skips the GTK4 event-debug GUI (drops the
    ## gtk4 transitive dep that no v1 desktop story needs).
    ## ``tests=false`` skips the upstream test suite to keep the build
    ## hermetic + fast.
    ## ``libwacom=false`` drops wacom-tablet integration.
    ## ``udev-dir=/lib/udev`` installs udev rules under the LSB
    ## canonical path.
    "-Ddocumentation=false"
    "-Ddebug-gui=false"
    "-Dtests=false"
    "-Dlibwacom=false"
    "-Dudev-dir=/lib/udev"
    "--buildtype=release"

  library libinput:
    ## ``libinput.so`` — the input-device abstraction shared library
    ## linked by wlroots / Mutter / KWin. v1 records the artifact
    ## only; the per-artifact build body lands in M9.L when the
    ## convention's ninja-spawn + install-glue closes.
    discard

  executable libinputBin:
    ## ``libinput`` (CLI tool — yes, the binary has the same name as
    ## the library) — the diagnostic command-line tool exposed via
    ## the upstream build; ships sub-commands ``list-devices``,
    ## ``debug-events``, ``measure``, ``record``, ``replay``, ...
    ##
    ## We register it under the DSL identifier ``libinputBin`` to
    ## avoid a Nim-level collision with the ``libinput`` library
    ## name; the M9.L install glue will resolve it to the
    ## ``$prefix/bin/libinput`` filename. v1 records the artifact
    ## only.
    discard

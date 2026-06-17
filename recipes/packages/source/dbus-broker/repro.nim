## Source-from-tarball dbus-broker recipe — the FIRST real
## from-source production recipe to exercise the M9.H/I/K trio
## (fetch: + mesonOptions: + convention-layer fetch-action emission).
##
## ## Why this recipe is SEPARATE from the NDE-C de-foundation recipe
##
## ``recipes/packages/de-foundation/dbus-broker/repro.nim`` is the
## NDE0-D config-and-units recipe — it emits ``dbus.socket`` /
## ``dbus.service`` unit files, ``/etc/passwd`` + ``/etc/group``
## managed blocks for the ``messagebus`` user, and a system-bus
## policy file. It does NOT build the broker binary; the broker
## binary is sourced from the (deferred) apt-jammy .deb in v1.
##
## This recipe (``dbusBrokerSource``) is the COMPLEMENT — it builds
## the ``dbus-broker`` + ``dbus-broker-launch`` binaries from the
## upstream tarball via meson/ninja. The two recipes are wired into
## the SAME package universe but live at different paths so the
## NDE0-D config-emission cache key is isolated from the upstream
## tarball sha256 (a v36 → v37 source bump invalidates only this
## recipe, not the unit-file emissions).
##
## ## sha256 strategy
##
## We vendor the v36 tarball at
## ``recipes/packages/source/dbus-broker/vendor/dbus-broker-v36.tar.gz``
## and reference it via a ``file://`` URL. This is the safest
## deterministic-test option per the M9.K acceptance plan: the
## upstream GitHub URL is recorded as ``sourceUrl`` in the
## ``versions:`` block for documentation / future-bump purposes, but
## the live ``fetch:`` block points at the vendored copy so the
## convention layer's emitted fetch action is offline-reproducible.
##
## sha256 = 5058a81eea8086636ef09a670d103e35e650a6f0200aadc2f59f3fb6e76c37b8
##  (computed locally over the vendored
##  ``dbus-broker-v36.tar.gz``, 241,290 bytes).
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
##   3. a ``ninja`` compile BuildAction.
##   4. install/output collection actions for the two executables.
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ninja-spawn + install glue lands in M9.L; the recipe
## records the executable artifacts via the ``executable`` block so
## the M9.K artifact registry already knows what binaries to expect.
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to the
## production-equivalent set (no audit / no SELinux / no AppArmor /
## release buildtype / linux-4-17 codepath enabled / reference-test
## disabled). Downstream configuration knobs would live here when the
## per-distro variants (Ubuntu / Fedora / Arch) need different
## strategies. For now the recipe stays declarative-only.

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package dbusBrokerSource:
  ## From-source dbus-broker — first M9.H/I/K production recipe.
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``mesonOptions:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"meson"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right
  ## URL + hash + flags.

  defaultToolProvisioning "path"

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical GitHub
    ## tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    "36":
      sourceRevision = "refs/tags/v36"
      sourceUrl = "https://github.com/bus1/dbus-broker/archive/refs/tags/v36.tar.gz"
      sourceRepository = "https://github.com/bus1/dbus-broker"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 241,290-byte tarball
    ## downloaded once from the upstream tag URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/dbus-broker/vendor/dbus-broker-v36.tar.gz"
    sha256: "5058a81eea8086636ef09a670d103e35e650a6f0200aadc2f59f3fb6e76c37b8"
    extractStrip: 1

  uses:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``.
    "meson >=1.3"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — dbus-broker is plain C11 with no
    ## C++ component, so the C compiler is sufficient.
    "gcc >=11"

  mesonOptions:
    ## Flag set mirroring the production-distro default (Debian /
    ## Fedora ship the same toggles). Order is load-bearing: meson
    ## evaluates options left-to-right and the ``--buildtype=release``
    ## sentinel lives at the tail so any override (e.g. a future
    ## debug-build variant) can append ``--buildtype=debug`` later
    ## without re-ordering this block.
    "-Daudit=false"
    "-Dlauncher=true"
    "-Dlinux-4-17=true"
    "-Dreference-test=false"
    "-Dselinux=false"
    "-Dapparmor=false"
    "--buildtype=release"

  executable dbusBroker:
    ## ``/usr/bin/dbus-broker`` — the core message-bus broker daemon.
    ## v1 records the artifact only; the per-artifact build body lands
    ## in M9.L when the convention's ninja-spawn + install-glue closes.
    discard

  executable dbusBrokerLaunch:
    ## ``/usr/bin/dbus-broker-launch`` — the activation helper the
    ## NDE0-D ``dbus.service`` unit invokes when
    ## ``busActivationStrategy = basBroker``.
    discard

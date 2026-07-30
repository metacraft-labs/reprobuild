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
## Use the maintainer-generated v36 release tarball. Unlike GitHub's
## automatic tag archive, this distribution includes the c-util Meson
## subprojects required for an offline, source-complete build.
##
## sha256 = d333d99bd2688135b6d6961e7ad1360099d186078781c87102230910ea4e162b
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
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

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

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical GitHub
    ## tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    "36":
      sourceRevision = "refs/tags/v36"
      sourceUrl = "https://github.com/bus1/dbus-broker/releases/download/v36/dbus-broker-36.tar.xz"
      sourceRepository = "https://github.com/bus1/dbus-broker"

  fetch:
    ## The upstream distribution archive includes the source of all
    ## Meson fallback subprojects and is pinned by its byte hash.
    url: "https://github.com/bus1/dbus-broker/releases/download/v36/dbus-broker-36.tar.xz"
    sha256: "d333d99bd2688135b6d6961e7ad1360099d186078781c87102230910ea4e162b"
    extractStrip: 1

  nativeBuildDeps:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``.
    "meson >=1.3"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — dbus-broker is plain C11 with no
    ## C++ component, so the C compiler is sufficient.
    "gcc >=11"

  buildDeps:
    ## M9.R.15r.6 — dbus-broker's ``src/meson.build:75`` declares
    ## ``dependency('expat')`` for the bus configuration XML parser.
    ## Without expat on PKG_CONFIG_PATH meson setup short-fails with
    ## ``Dependency "expat" not found, tried pkgconfig``. Recipe-level
    ## buildDep on the sibling expat from-source recipe.
    "expat"
    ## libsystemd supplies sd-bus and daemon-notification APIs used by
    ## both broker executables.
    "systemd >=240"

  config:
    ## No prefix lifted from `mesonOptions:`; flags inlined in the `build:` block.
    discard
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

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `meson_package(...)` constructor.
    setCurrentOwningPackageOverride("dbusBrokerSource")
    try:
      let opts = @[
        "audit=false",
        "launcher=true",
        "linux-4-17=true",
        "reference-test=false",
        "selinux=false",
        "apparmor=false",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("dbusBroker")
      discard pkg.executable("dbusBrokerLaunch")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    "expat"
    "systemd >=240"

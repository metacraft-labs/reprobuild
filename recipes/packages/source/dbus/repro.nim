## Source-from-tarball dbus recipe — the FORTIETH real from-source
## production recipe to exercise the M9.H/I/K trio. dbus is the
## **reference freedesktop D-Bus daemon** — distinct from the sibling
## ``dbusBrokerSource`` recipe (``recipes/packages/source/dbus-broker/``)
## which packages the alternative bus1 broker implementation. Both
## ship an activation helper (``dbus-launch`` / ``dbus-broker-launch``)
## and both speak the same wire protocol on the system bus + the
## per-session bus, but they differ at two levels:
##
##   * **Build system** — historical reference dbus used autotools, but
##     upstream 1.16.x ships meson-only (the autotools layer was retired
##     prior to the 1.16 cut: the 1.16.0 tarball contains ``meson.build``
##     + ``CMakeLists.txt`` but NO ``configure``/``configure.ac``).
##     dbus-broker also uses meson + ninja. So this recipe drives the
##     meson ``mesonOptions:`` channel for the reference daemon, with
##     option names matched to the upstream ``meson_options.txt``.
##   * **Daemon binary** — reference ships ``/usr/bin/dbus-daemon`` (the
##     binary the NDE0-D ``dbus.service`` unit invokes when
##     ``busActivationStrategy = basDaemon``); dbus-broker ships
##     ``/usr/bin/dbus-broker`` (invoked when
##     ``busActivationStrategy = basBroker``).
##   * **Library** — reference ships ``libdbus-1.so`` (the canonical
##     libdbus client library every glib / Qt / KDE D-Bus binding links
##     against); dbus-broker does NOT ship a client library — every
##     downstream client links against reference ``libdbus-1.so``
##     regardless of which daemon implementation is running.
##
## The two recipes co-exist in the package universe because (a)
## reference ``libdbus-1.so`` is consumed even when dbus-broker is the
## active daemon implementation, and (b) the NDE0-D config-and-units
## recipe needs to be able to plant either daemon's unit file based on
## the configurable.
##
## ## Why dbus matters for the v1 desktop story
##
## D-Bus is the canonical IPC bus for every Linux desktop stack. Every
## modern GNOME / Plasma / sway desktop runs at minimum one system bus
## (``dbus.socket`` / ``dbus.service`` activated under systemd) plus a
## per-user session bus (``dbus.service`` user unit activated under the
## user manager). The libdbus client library is consumed by every
## major desktop component:
##
##   * GLib's GIO wraps libdbus in ``GDBusConnection`` / ``GDBusProxy``
##     for GNOME applications.
##   * QtDBus wraps libdbus in ``QDBusConnection`` / ``QDBusInterface``
##     for Qt/KDE applications.
##   * systemd's ``sd-bus`` is a from-scratch reimplementation but the
##     reference daemon still routes both ``sd-bus`` and libdbus
##     clients on the same socket.
##   * polkit, NetworkManager, BlueZ, PulseAudio, PipeWire, GNOME
##     Settings Daemon, Plasma's krunner — all libdbus consumers.
##
## ## sha256 strategy
##
## We vendor the upstream 1.16.0 .tar.xz at
## ``recipes/packages/source/dbus/vendor/dbus-1.16.0.tar.xz`` and
## reference it via a ``file://`` URL. The freedesktop release URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 1.16.0 (current upstream stable)
##
## dbus releases are cut on dbus.freedesktop.org under tags of the form
## ``dbus-<X>.<Y>.<Z>``. 1.16.0 is the current stable in the 1.16.x
## line as of mid-2026 and the ABI is stable since the 1.14 cut —
## anything ``>=1.14`` covers every consumer's pinning.
##
## sha256 = 9f8ca5eb51cbe09951aec8624b86c292990ae2428b41b856e2bed17ec65c8849
##  (computed locally over the vendored ``dbus-1.16.0.tar.xz``,
##  1,114,680 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_meson convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``mesonOptions:`` block off this package's
## registries and lowers them into fetch + ``meson setup`` + ``ninja``
## BuildActions; the per-artifact build body + install glue lands in
## M9.L; the recipe records the executable + library artifacts via the
## ``executable`` / ``library`` blocks so the M9.K artifact registry
## already knows what binaries / shared objects to expect.
##
## ## Artifacts
##
##   * ``dbusDaemon`` (executable) — ``/usr/bin/dbus-daemon`` the core
##     message-bus daemon (the binary the NDE0-D ``dbus.service`` unit
##     invokes when ``busActivationStrategy = basDaemon``). v1 records
##     the artifact only; per-artifact build body lands in M9.L.
##   * ``libDbus1`` (library) — ``libdbus-1.so`` the canonical libdbus
##     client library. Consumed by every glib / Qt / KDE D-Bus binding
##     regardless of which daemon implementation is active. The upstream
##     SONAME ``dbus-1`` is camelCased to ``libDbus1`` per the libGlib2 /
##     libKF6I18n precedent of dropping the hyphen + version-suffix
##     separator while preserving the canonical ``lib`` prefix.
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to the
## modern-desktop baseline per the task brief. Option names map to the
## upstream ``meson_options.txt`` 1:1:
##
##   * ``modular_tests=disabled``    — skip the upstream modular test
##                                      suite (the historical autotools
##                                      ``--disable-tests``).
##   * ``intrusive_tests=false``     — skip in-tree intrusive tests.
##   * ``installed_tests=false``     — skip ``installed-tests`` artefact
##                                      generation.
##   * ``x11_autolaunch=disabled``   — drop the legacy ``dbus-launch``
##                                      X11 autolaunch helper (the
##                                      historical autotools
##                                      ``--without-x``); every modern
##                                      desktop uses Wayland.
##   * ``doxygen_docs=disabled``     — skip the Doxygen API docs build
##                                      (the historical autotools
##                                      ``--disable-doxygen-docs``).
##   * ``xml_docs=disabled``         — skip the DocBook XML manpage
##                                      build (the historical autotools
##                                      ``--disable-xml-docs``).
##   * ``ducktype_docs=disabled``    — skip the Ducktype documentation
##                                      build (introduced in the meson
##                                      port; no autotools precedent).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package dbusSource:
  ## From-source reference D-Bus daemon — fortieth M9.H/I/K production
  ## recipe. Upstream retired autotools before the 1.16 cut so this
  ## recipe drives the meson ``mesonOptions:`` channel (the sibling
  ## ``dbusBrokerSource`` covers the alternative bus1 broker
  ## implementation also via meson + ninja). Ships ONE executable
  ## (``dbusDaemon``) + ONE library (``libDbus1``) from a single
  ## ``meson setup`` + ``ninja`` invocation.
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``mesonOptions:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"meson"`` channel) and
  ## lowers them into fetch + meson-setup BuildActions wired with the
  ## right URL + hash + flags. One executable + one library artifact
  ## recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## freedesktop release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical GitLab project
    ## that hosts the reference dbus source tree.
    "1.16.0":
      sourceRevision = "dbus-1.16.0"
      sourceUrl = "https://dbus.freedesktop.org/releases/dbus/dbus-1.16.0.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/dbus/dbus"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 1,114,680-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "https://dbus.freedesktop.org/releases/dbus/dbus-1.16.0.tar.xz"
    sha256: "9f8ca5eb51cbe09951aec8624b86c292990ae2428b41b856e2bed17ec65c8849"
    extractStrip: 1

  nativeBuildDeps:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``.
    "meson >=1.3"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — dbus is plain C99.
    "gcc >=11"
    ## pkg-config is used by the meson configure step to probe for
    ## expat (the XML parser dbus uses for the introspection XML +
    ## bus-config file parsing).
    "pkg-config"

  buildDeps:
    ## expat is the SAX XML parser dbus uses for the introspection
    ## XML layer + the bus-config file parser. Sibling from-source
    ## ``expatSource`` recipe pins ``>=2.6``.
    "expat >=2.6"

  config:
    ## No prefix lifted from `mesonOptions:`; flags inlined in the `build:` block.
    discard
  executable dbusDaemon:
    ## ``/usr/bin/dbus-daemon`` — the core reference message-bus daemon
    ## the NDE0-D ``dbus.service`` unit invokes when
    ## ``busActivationStrategy = basDaemon``. v1 records the artifact
    ## only; the per-artifact build body lands in M9.L when the
    ## convention's make-spawn + install-glue closes.
    discard

  library libDbus1:
    ## ``libdbus-1.so`` — the canonical libdbus client library every
    ## glib / Qt / KDE D-Bus binding links against. Consumed regardless
    ## of which daemon implementation (reference dbus-daemon vs
    ## dbus-broker) is active; the wire protocol is the same. The
    ## upstream SONAME ``dbus-1`` is camelCased to ``libDbus1`` per the
    ## libGlib2 / libKF6I18n precedent of dropping the hyphen + version-
    ## suffix separator while preserving the canonical ``lib`` prefix.
    ## v1 records the artifact only.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `meson_package(...)` constructor.
    ##
    ## M9.R.15a.1 — upstream dbus 1.16.0 ships meson-only; the
    ## historical autotools shape produced ``../src/configure: No such
    ## file or directory`` on apply. Option names mapped 1:1 from
    ## ``recipes/packages/source/dbus/src/meson_options.txt``.
    setCurrentOwningPackageOverride("dbusSource")
    try:
      let opts = @[
        "modular_tests=disabled",
        "intrusive_tests=false",
        "installed_tests=false",
        "x11_autolaunch=disabled",
        "doxygen_docs=disabled",
        "xml_docs=disabled",
        "ducktype_docs=disabled",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("dbusDaemon")
      discard pkg.library("libDbus1")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

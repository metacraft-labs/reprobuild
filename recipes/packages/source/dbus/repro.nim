## Source-from-tarball dbus recipe — the FORTIETH real from-source
## production recipe to exercise the M9.H/I/K trio. dbus is the
## **reference freedesktop D-Bus daemon** — distinct from the sibling
## ``dbusBrokerSource`` recipe (``recipes/packages/source/dbus-broker/``)
## which packages the alternative bus1 broker implementation. Both
## ship an activation helper (``dbus-launch`` / ``dbus-broker-launch``)
## and both speak the same wire protocol on the system bus + the
## per-session bus, but they differ at three levels:
##
##   * **Build system** — reference dbus uses autotools (``./configure``
##     + ``make``); dbus-broker uses meson + ninja. So this recipe is
##     the FIRST from-source dbus daemon to drive the autotools
##     ``configureFlags:`` channel for the bus daemon family.
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
## The c_cpp_autotools convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``configureFlags:`` block off this package's
## registries and lowers them into fetch + ``./configure`` + ``make``
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
## v1 ships NO configurables — the configure flags are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``--disable-static``        — skip the static archive (not used
##                                    by the v1 desktop story).
##   * ``--disable-tests``         — skip the upstream test suite to
##                                    keep the build hermetic + fast.
##   * ``--without-x``             — skip the legacy ``dbus-launch``
##                                    X11 helper (every modern desktop
##                                    uses Wayland; the X11 helper is
##                                    only needed for ancient X-only
##                                    sessions).
##   * ``--disable-doxygen-docs``  — skip the Doxygen API documentation
##                                    build (heavy Doxygen dependency
##                                    surface, not needed at runtime).
##   * ``--disable-xml-docs``      — skip the DocBook XML manpage build
##                                    (heavy XSLT dependency surface,
##                                    not needed at runtime; matches
##                                    the ``--without-docbook`` expat
##                                    precedent).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package dbusSource:
  ## From-source reference D-Bus daemon — fortieth M9.H/I/K production
  ## recipe and FIRST from-source dbus daemon to drive the autotools
  ## ``configureFlags:`` channel for the bus daemon family (the sibling
  ## ``dbusBrokerSource`` covers the alternative bus1 broker
  ## implementation via meson + ninja). Ships ONE executable
  ## (``dbusDaemon``) + ONE library (``libDbus1``) from a single
  ## ``./configure`` + ``make`` invocation.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
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
    url: "file:///metacraft/reprobuild/recipes/packages/source/dbus/vendor/dbus-1.16.0.tar.xz"
    sha256: "9f8ca5eb51cbe09951aec8624b86c292990ae2428b41b856e2bed17ec65c8849"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``.
    "autoconf"
    ## automake provides the upstream ``Makefile.in`` templates the
    ## release tarball pre-generates.
    "automake"
    ## libtool provides the ``./libtool`` shim the autotools build
    ## drives for ``--disable-static`` to honour the shared-only build
    ## semantics correctly.
    "libtool"
    ## make is the build-system driver — the c_cpp_autotools
    ## convention's compile action invokes ``make`` after
    ## ``./configure``.
    "make"
    ## gcc is the host C toolchain — dbus is plain C99.
    "gcc >=11"
    ## pkg-config is used by the autotools configure step to probe for
    ## expat (the XML parser dbus uses for the introspection XML +
    ## bus-config file parsing).
    "pkg-config"

  buildDeps:
    ## expat is the SAX XML parser dbus uses for the introspection
    ## XML layer + the bus-config file parser. Sibling from-source
    ## ``expatSource`` recipe pins ``>=2.6``.
    "expat >=2.6"

  config:
    ## No prefix lifted from `configureFlags:`; flags inlined in the `build:` block.
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
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `autotools_package(...)` constructor.
    setCurrentOwningPackageOverride("dbusSource")
    try:
      let opts = @[
        "--disable-static",
        "--disable-tests",
        "--without-x",
        "--disable-doxygen-docs",
        "--disable-xml-docs",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
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

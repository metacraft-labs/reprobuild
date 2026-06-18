## Source-from-tarball systemd recipe — the THIRTY-FIRST real
## from-source production recipe to exercise the M9.H/I/K trio.
## systemd's unique coverage angle vs the prior thirty recipes is the
## SIX-ARTIFACT (mixed-kind) single-package shape: four executables
## (``systemd`` the init daemon, ``systemctl`` the service control CLI,
## ``journalctl`` the log CLI, ``systemd-logind`` the seat manager
## daemon) PLUS two libraries (``libsystemd.so`` the IPC client library,
## ``libudev.so`` the device-database library) all built from one meson
## invocation. Every prior multi-artifact recipe shipped at most six
## (qt6-base's six libs) or three (sddm's two-exec + one-lib) — systemd
## is the FIRST recipe to ship a four-exec + two-lib mixed-kind shape
## from a single ``package`` macro.
##
## ## Why systemd matters for the v1 desktop story
##
## systemd is the init system + service manager + session manager + log
## aggregator underpinning every modern Linux desktop. Every recipe in
## the NDE-K1 manifest layer drops at least one ``.service`` unit that
## systemd ``ExecStart``s (gdm.service, sddm.service, dbus-broker.service,
## systemd-logind.service, etc.). libsystemd is the IPC client library
## every daemon links to talk to the init daemon (sd_notify(), sd_bus,
## sd_event); libudev is the device-database library every greeter /
## window manager consumes to enumerate input devices + monitors.
##
## ## sha256 strategy
##
## We vendor the upstream v257 .tar.gz at
## ``recipes/packages/source/systemd/vendor/systemd-257.tar.gz`` and
## reference it via a ``file://`` URL. The github.com release URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 257 (current upstream stable)
##
## systemd releases are cut on GitHub under tags of the form ``v<N>``
## (no semver — systemd uses a flat monotonic version number). v257 is
## the current stable as of mid-2026 and the ABI of libsystemd /
## libudev has been stable since v240 — anything ``>=240`` covers the
## glib2 / qt6-base / desktop-stack consumption.
##
## sha256 = 14f6907eb5e289d8c39cbe1ef891ca54d8a0e3582c986a9ef5844b3f29add43b
##  (computed locally over the vendored ``systemd-257.tar.gz``,
##  16,184,128 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
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
##   4. install/output collection actions for the six artifacts (M9.L).
##
## M9.K only wires (1) + the flag-injection portion of (2). The
## downstream ninja-spawn + install glue lands in M9.L; the recipe
## records the six artifacts via the ``executable`` + ``library`` blocks
## so the M9.K artifact registry already knows what to expect.
##
## ## Artifacts
##
## systemd's meson build emits a vast set of binaries + libraries; we
## register only the six load-bearing ones for the v1 desktop story:
##
##   * ``systemdInit``    — ``/lib/systemd/systemd`` the init daemon
##                           that runs as PID 1.
##   * ``systemctl``      — ``/usr/bin/systemctl`` the service control
##                           CLI used to start/stop/status units.
##   * ``journalctl``     — ``/usr/bin/journalctl`` the log inspection
##                           CLI used to query the binary journal.
##   * ``systemdLogind``  — ``/lib/systemd/systemd-logind`` the seat /
##                           session manager daemon.
##   * ``libSystemd``     — ``libsystemd.so`` the IPC client library
##                           every daemon links to talk to the init
##                           daemon (sd_notify, sd_bus, sd_event).
##   * ``libUdev``        — ``libudev.so`` the device-database library
##                           every greeter / WM consumes to enumerate
##                           input devices + monitors.
##
## The hyphenated upstream binary names ``systemd-logind`` is camelCased
## to ``systemdLogind``; the bare-``systemd`` init daemon is renamed to
## ``systemdInit`` to avoid identifier collision with the package name's
## ``systemd`` prefix (matching the sddm / sddmGreeter naming convention
## for disambiguating package-level daemon binaries from short package
## names).
##
## ## Configurables
##
## v1 ships NO configurables — the meson options are hardcoded to the
## modern-desktop baseline per the task brief:
##
##   * ``mode=release``         — production-mode build (vs developer-
##                                 mode which enables extra assertions).
##   * ``tests=false``          — skip the upstream test suite.
##   * ``man=disabled``         — skip man-page generation.
##   * ``translations=false``   — skip the native-language-support
##                                 translation build.
##   * ``xdg-autostart=false``  — skip the XDG autostart generator
##                                 (NDE-K1's manifest layer owns the
##                                 autostart units explicitly).
##   * ``networkd=false``       — skip systemd-networkd (NDE-K1 v1 uses
##                                 NetworkManager, not networkd).
##   * ``resolve=false``        — skip systemd-resolved (NDE-K1 v1 uses
##                                 the host resolver, not resolved).
##   * ``timesyncd=false``      — skip systemd-timesyncd (NDE-K1 v1
##                                 uses chrony, not timesyncd).
##   * ``homed=false``          — skip systemd-homed (v1 uses traditional
##                                 /home, not portable home dirs).
##   * ``userdb=false``         — skip systemd-userdbd (v1 uses
##                                 traditional NSS, not userdb).
##   * ``importd=false``        — skip systemd-importd (v1 doesn't need
##                                 OS image management).
##   * ``portabled=false``      — skip systemd-portabled (v1 doesn't
##                                 use portable services).
##   * ``polkit=false``         — skip the polkit dep (NDE-K1's manifest
##                                 layer owns polkit policy install
##                                 explicitly).
##   * ``--buildtype=release``  — release-mode optimisation; matches the
##                                 sibling from-source recipes.

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package systemdSource:
  ## From-source systemd — thirty-first M9.H/I/K production recipe and
  ## the SEVENTEENTH meson-driven recipe. FIRST recipe in the corpus to
  ## ship a four-executable + two-library mixed-kind artifact set from
  ## a single ``package`` macro.
  ##
  ## Tier-2b c_cpp_meson convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``mesonOptions:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"meson"`` channel) and lowers
  ## them into fetch + configure BuildActions wired with the right URL
  ## + hash + flags. Four executable + two library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## github.com release tarball URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical GitHub project
    ## that hosts the systemd source tree.
    "257":
      sourceRevision = "v257"
      sourceUrl = "https://github.com/systemd/systemd/archive/refs/tags/v257.tar.gz"
      sourceRepository = "https://github.com/systemd/systemd"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 16,184,128-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/systemd/vendor/systemd-257.tar.gz"
    sha256: "14f6907eb5e289d8c39cbe1ef891ca54d8a0e3582c986a9ef5844b3f29add43b"
    extractStrip: 1

  uses:
    ## meson is the build-system driver — the c_cpp_meson convention's
    ## configure action invokes ``meson setup``. systemd v257 requires
    ## meson 1.2 for the modern dependency-fallback semantics it
    ## relies on.
    "meson >=1.2"
    ## ninja is meson's default backend — the compile action invokes
    ## ``ninja`` against the meson build directory.
    "ninja >=1.10"
    ## gcc is the host C toolchain — systemd is C11 with light use of
    ## GNU extensions.
    "gcc >=11"
    ## libcap supplies the POSIX capabilities library systemd consumes
    ## to drop-and-keep capabilities when forking unit processes.
    "libcap >=2.60"
    ## libmount is the libblkid + libmount stack from util-linux that
    ## systemd's mount-unit machinery consumes.
    "util-linux >=2.36"
    ## libacl supplies the POSIX ACL library systemd's journald uses
    ## to grant per-group read access to the binary journal.
    "libacl >=2.3"
    ## libcrypt supplies the password-hashing primitives systemd's
    ## userdb fallback path consumes.
    "libcrypt >=4.4"
    ## kmod supplies the kernel-module loader library systemd's
    ## systemd-modules-load.service consumes.
    "kmod >=29"
    ## libseccomp supplies the seccomp BPF filter library systemd's
    ## per-unit SystemCallFilter= directive compiles against.
    "libseccomp >=2.5"
    ## pkg-config is used by the meson configure step to probe for
    ## the libcap / libmount / libacl / libcrypt / kmod / libseccomp
    ## dependencies.
    "pkg-config"

  mesonOptions:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: meson evaluates options
    ## left-to-right and the ``--buildtype=release`` sentinel lives at
    ## the tail so any override (e.g. a future debug-build variant)
    ## can append ``--buildtype=debug`` later without re-ordering this
    ## block.
    ##
    ## ``mode=release`` enables production-mode build.
    ## ``tests=false`` skips the upstream test suite.
    ## ``man=disabled`` skips man-page generation.
    ## ``translations=false`` skips the NLS translation build.
    ## ``xdg-autostart=false`` skips the XDG autostart generator.
    ## ``networkd=false`` skips systemd-networkd.
    ## ``resolve=false`` skips systemd-resolved.
    ## ``timesyncd=false`` skips systemd-timesyncd.
    ## ``homed=false`` skips systemd-homed.
    ## ``userdb=false`` skips systemd-userdbd.
    ## ``importd=false`` skips systemd-importd.
    ## ``portabled=false`` skips systemd-portabled.
    ## ``polkit=false`` skips the polkit dependency.
    "-Dmode=release"
    "-Dtests=false"
    "-Dman=disabled"
    "-Dtranslations=false"
    "-Dxdg-autostart=false"
    "-Dnetworkd=false"
    "-Dresolve=false"
    "-Dtimesyncd=false"
    "-Dhomed=false"
    "-Duserdb=false"
    "-Dimportd=false"
    "-Dportabled=false"
    "-Dpolkit=false"
    "--buildtype=release"

  executable systemdInit:
    ## ``/lib/systemd/systemd`` — the init daemon that runs as PID 1.
    ## Renamed from the bare-``systemd`` upstream binary name to
    ## ``systemdInit`` to avoid identifier collision with the package
    ## name's ``systemd`` prefix (matching the sddm / sddmGreeter
    ## naming convention for disambiguating package-level daemon
    ## binaries from short package names). v1 records the artifact
    ## only; the per-artifact build body lands in M9.L when the
    ## convention's ninja-spawn + install-glue closes.
    discard

  executable systemctl:
    ## ``/usr/bin/systemctl`` — the service control CLI used to
    ## start/stop/status units. Every desktop component eventually
    ## invokes systemctl directly or indirectly (gdm.service start,
    ## sddm.service start, etc.). v1 records the artifact only.
    discard

  executable journalctl:
    ## ``/usr/bin/journalctl`` — the log inspection CLI used to query
    ## the binary journal. Plasma's Discover updater + GNOME's
    ## Software Center both shell out to journalctl for failure
    ## diagnostics. v1 records the artifact only.
    discard

  executable systemdLogind:
    ## ``/lib/systemd/systemd-logind`` — the seat / session manager
    ## daemon. gdm + sddm both register their greeter sessions with
    ## logind; logind in turn owns the VT-switching + session-lock
    ## semantics. The hyphenated upstream binary name
    ## ``systemd-logind`` is camelCased to ``systemdLogind``. v1
    ## records the artifact only.
    discard

  library libSystemd:
    ## ``libsystemd.so`` — the IPC client library every daemon links
    ## to talk to the init daemon (sd_notify(), sd_bus, sd_event).
    ## Consumed by gdm (logind seat enumeration), sddm (logind seat
    ## enumeration), dbus-broker (sd_bus for D-Bus IPC), and
    ## NetworkManager (sd_event for event-loop integration).
    ## v1 records the artifact only.
    discard

  library libUdev:
    ## ``libudev.so`` — the device-database library every greeter /
    ## window manager consumes to enumerate input devices + monitors.
    ## Consumed by mutter / kwin / sway / wlroots (udev monitor
    ## enumeration), libinput (udev device enumeration), and
    ## fontconfig (udev hot-plug for font-cache invalidation on
    ## external font mounts). v1 records the artifact only.
    discard

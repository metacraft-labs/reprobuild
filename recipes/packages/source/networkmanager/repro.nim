## Source-from-tarball NetworkManager recipe — the SEVENTIETH real
## from-source production recipe to exercise the M9.H/I/K trio.
## NetworkManager is THE canonical network configuration daemon on
## modern Linux desktops: every NDE-K1 v1 desktop (sway / GNOME /
## Plasma) consumes its D-Bus API for Wi-Fi connection management,
## Ethernet hot-plug response, VPN routing, and the per-application
## network-status indicators.
##
## NetworkManager joins ``alsaLibSource`` + ``pipewireSource`` +
## ``wireplumberSource`` in the network + audio infrastructure batch
## adding the four runtime daemons + libraries every modern desktop
## (sway / GNOME / Plasma) consumes.
##
## ## Why NetworkManager matters for the v1 desktop story
##
## NetworkManager owns the desktop network plane end-to-end:
##
##   * **Wi-Fi connection management**: NetworkManager's wifi plugin
##     drives wpa_supplicant for WPA2/WPA3 authentication and stores
##     per-SSID connection profiles under
##     ``/etc/NetworkManager/system-connections/``. GNOME's
##     gnome-control-center Wi-Fi panel, Plasma's
##     plasma-nm widget, and sway's nm-applet all consume this surface.
##   * **Ethernet hot-plug**: NetworkManager listens to udev
##     netlink events and brings up DHCP / static-IP configurations
##     when a wired link goes up. The ``NetworkManager-wait-online``
##     companion unit blocks the systemd default.target until
##     connectivity is established.
##   * **VPN integration**: NetworkManager's plugin architecture
##     supports OpenVPN, WireGuard, IPsec/IKEv2, and PPTP via
##     ``NetworkManager-<vpn>`` plugin packages. The
##     gnome-control-center Network panel and Plasma's network
##     widget surface these as first-class connection types.
##   * **Network-status indicators**: every desktop's status bar
##     widget (sway's waybar network module, GNOME shell's top-bar
##     network indicator, Plasma's system tray icon) consumes the
##     NetworkManager D-Bus interface
##     ``org.freedesktop.NetworkManager.Device.State`` for the
##     connection-state icon updates.
##   * **DNS resolution coordination**: NetworkManager writes
##     ``/etc/resolv.conf`` based on per-connection DNS settings,
##     coordinating with systemd-resolved when present or owning the
##     file directly when not. NDE-K1 v1 disables systemd-resolved so
##     NetworkManager owns resolv.conf directly.
##
## ## sha256 strategy
##
## Per the network + audio batch convention (matching the kernel +
## recent-batch precedent), we point the live ``fetch:`` URL at upstream
## directly (no vendoring), and pin the sha256 over the upstream tarball
## bytes. The hash is cross-checked against the nixpkgs
## ``networkmanager`` recipe at
## ``pkgs/by-name/ne/networkmanager/package.nix`` which fetches the
## same upstream archive via ``fetchurl``.
##
## ## Version choice — 1.56.0 (current upstream stable)
##
## NetworkManager releases are cut on gitlab.freedesktop.org under
## ``releases/<X>.<Y>.<Z>``. The 1.56.0 release is the current stable
## as of mid-2026 (matches the nixpkgs pin). NetworkManager moved its
## release-tarball hosting from download.gnome.org (the historical
## home pre-2022) to gitlab.freedesktop.org/.../releases/.../downloads/
## after the freedesktop migration; the task brief's pointer to
## download.gnome.org reflects the legacy URL form. The libnm-1 ABI
## has been stable since 1.0; any ``>=1.30`` covers the modern
## sway / GNOME / Plasma desktop story.
##
## sha256 = 59a32d385cc1e7ae26e43798c6f12d07ff6198abd041ec0620b3a08cfc021ccc
##  (cross-checked against nixpkgs's SRI-form
##  ``sha256-WaMtOFzB564m5DeYxvEtB/9hmKvQQewGILOgjPwCHMw=`` at
##  ``pkgs/by-name/ne/networkmanager/package.nix``, which decodes to
##  the same hex over the same upstream tarball bytes).
##
## ## Build shape
##
## NetworkManager's build system is autotools (the project has NOT
## migrated to meson). The c_cpp_autotools convention (M9.K) reads
## both the M9.H ``fetch:`` block and the M9.I ``configureFlags:``
## block off this package's registries and lowers them into fetch +
## ``./configure`` + ``make`` BuildActions; the per-artifact build
## body + install glue lands in M9.L; the recipe records the
## executable + executable + library artifacts via the two
## ``executable`` + one ``library`` blocks so the M9.K artifact
## registry already knows what binaries + shared object to expect.
##
## ## Artifacts
##
## NetworkManager's autotools build emits a vast set of binaries +
## libraries + per-device plugins + nss modules; we register the
## three load-bearing ones for the v1 desktop story:
##
##   * ``nmDaemon`` — ``/usr/sbin/NetworkManager``, the connection
##                    manager daemon. Started by
##                    ``NetworkManager.service`` (system systemd
##                    unit) on every boot, owns the connection
##                    state-machine + the D-Bus name
##                    ``org.freedesktop.NetworkManager``.
##   * ``nmcli``    — ``/usr/bin/nmcli``, the connection-management
##                    CLI used by ops + by the user-session activation
##                    layer to bring up specific connection profiles
##                    declaratively. NDE-K1 v1 manifest activations
##                    shell out to nmcli for connection-profile
##                    install.
##   * ``libNm``    — ``libnm.so``, the C library every desktop
##                    network widget (sway's waybar network module,
##                    GNOME shell's top-bar network indicator,
##                    Plasma's system tray icon) links against to
##                    consume the NetworkManager D-Bus interface
##                    via the high-level ``NMClient`` /
##                    ``NMDevice`` /``NMActiveConnection`` GObject
##                    types.
##
## The bare-``NetworkManager`` upstream binary name is renamed to
## ``nmDaemon`` to (1) avoid identifier collision with the package
## name's ``networkmanager`` prefix and (2) follow the
## systemdInit / sddmGreeter convention of disambiguating
## package-level daemon binaries from short package names. The
## SONAME ``libnm`` is camelCased to ``libNm`` per the libAsound /
## libExpat / libGlib2 precedent of preserving the canonical
## ``lib`` prefix while PascalCasing the SONAME body.
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--disable-static``           — skip the static archive (not
##                                        used by the v1 desktop story;
##                                        consumers link dynamically).
##   * ``--disable-tests``            — skip the upstream test suite to
##                                        keep the build hermetic.
##   * ``--disable-introspection``    — skip GObject Introspection
##                                        (drops the g-ir-scanner
##                                        toolchain dep; matches glib2
##                                        + wireplumber precedents).
##   * ``--without-docs``             — skip the gtk-doc + man-page
##                                        build (heavy XSLT dependency
##                                        surface).
##   * ``--without-systemd-journal``  — skip the libsystemd-journal
##                                        log-target build (use the
##                                        plain syslog target instead;
##                                        avoids a hard libsystemd
##                                        version coupling).
##   * ``--with-modify-system=true``  — allow ``nmcli`` modifications
##                                        to system-wide connection
##                                        profiles without polkit
##                                        gating (NDE-K1 v1 manifest
##                                        activations require this for
##                                        declarative connection-
##                                        profile install).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package networkManagerSource:
  ## From-source NetworkManager — seventieth M9.H/I/K production
  ## recipe. THE canonical network configuration daemon on modern
  ## Linux desktops: every NDE-K1 v1 desktop consumes its D-Bus API
  ## for Wi-Fi / Ethernet / VPN management and per-application
  ## network-status indicators.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention
  ## layer reads the ``fetch:`` block (registered via
  ## ``registeredFetchSpec``) and the ``configureFlags:`` block
  ## (registered via ``registeredBuildFlags`` on the ``"configure"``
  ## channel) and lowers them into fetch + configure BuildActions
  ## wired with the right URL + hash + flags. Two-executable +
  ## one-library artifact recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## gitlab.freedesktop.org release tarball URL — the same URL the
    ## live ``fetch:`` block points at (no vendoring per the network +
    ## audio batch convention).
    ##
    ## ``sourceRepository`` points at the canonical
    ## gitlab.freedesktop.org project that hosts the NetworkManager
    ## source tree.
    "1.56.0":
      sourceRevision = "1.56.0"
      sourceUrl = "https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/releases/1.56.0/downloads/NetworkManager-1.56.0.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/NetworkManager/NetworkManager"

  fetch:
    ## Upstream gitlab.freedesktop.org release-tarball URL —
    ## out-of-band fetch on first build, then cached by the M9.K
    ## fetch action keyed on (url, sha256, extractStrip). Matches the
    ## kernel-precedent pattern of NOT vendoring tarballs.
    ##
    ## sha256 was cross-checked against nixpkgs's
    ## ``pkgs/by-name/ne/networkmanager/package.nix`` SRI-form hash
    ## ``sha256-WaMtOFzB564m5DeYxvEtB/9hmKvQQewGILOgjPwCHMw=`` which
    ## decodes to the hex value pinned below.
    url: "https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/releases/1.56.0/downloads/NetworkManager-1.56.0.tar.xz"
    sha256: "59a32d385cc1e7ae26e43798c6f12d07ff6198abd041ec0620b3a08cfc021ccc"
    extractStrip: 1

  nativeBuildDeps:
    ## autoconf generates the upstream ``configure`` script when the
    ## release tarball ships a stale ``configure.ac``. NetworkManager's
    ## release tarball pre-generates ``configure`` but the convention's
    ## fallback re-runs ``autoconf`` if the script is missing.
    "autoconf"
    ## automake provides the ``Makefile.in`` templates the release
    ## tarball pre-generates.
    "automake"
    ## libtool provides the ``./libtool`` shim the autotools build
    ## drives for ``--disable-static`` to honour the shared-only
    ## build semantics correctly.
    "libtool"
    ## make is the build-system driver — the c_cpp_autotools
    ## convention's compile action invokes ``make`` after
    ## ``./configure``.
    "make"
    ## gcc is the host C toolchain — NetworkManager is C11 with light
    ## use of GNU extensions.
    "gcc >=11"
    ## pkg-config is used by the autotools configure step to probe for
    ## the glib2 + libnl + libuuid + dbus + libcurl dependencies.
    "pkg-config"

  buildDeps:
    ## glib2 supplies ``libglib-2.0`` + ``libgobject-2.0`` +
    ## ``libgio-2.0`` — NetworkManager's main loop integrates with
    ## GMainLoop and the NMClient / NMDevice public API are GObject
    ## types.
    "glib2 >=2.62"
    ## libxml2 supplies the XML parser NetworkManager's
    ## connection-import path uses for the legacy ifcfg-rh / network-
    ## scripts XML formats.
    "libxml2 >=2.9"
    ## util-linux supplies ``libuuid`` for the per-connection UUID
    ## generation NetworkManager uses to key system-connection
    ## profiles.
    "util-linux >=2.36"
    ## dbus supplies ``libdbus-1`` — NetworkManager's D-Bus interface
    ## is the primary client API every desktop widget consumes.
    "dbus >=1.12"
    ## openssl supplies ``libssl`` + ``libcrypto`` — NetworkManager's
    ## WPA2-Enterprise / 802.1X paths use OpenSSL for the TLS handshake
    ## with the RADIUS server via wpa_supplicant.
    "openssl >=3.0"
    ## systemd supplies ``libudev`` for netlink + udev device
    ## enumeration (the wired / wireless / Bluetooth interface probe).
    "systemd >=240"

  config:
    ## No prefix lifted from `configureFlags:`; flags inlined in the `build:` block.
    discard
  executable nmDaemon:
    ## ``/usr/sbin/NetworkManager`` — the connection manager daemon.
    ## Started by ``NetworkManager.service`` (system systemd unit) on
    ## every boot, owns the connection state-machine + the D-Bus
    ## name ``org.freedesktop.NetworkManager``. Renamed from the
    ## bare-``NetworkManager`` upstream binary name to ``nmDaemon``
    ## to avoid identifier collision with the package name's
    ## ``networkmanager`` prefix (matching the systemdInit /
    ## sddmGreeter naming convention for disambiguating package-level
    ## daemon binaries from short package names). v1 records the
    ## artifact only; the per-artifact build body lands in M9.L when
    ## the convention's make-spawn + install-glue closes.
    discard

  executable nmcli:
    ## ``/usr/bin/nmcli`` — the connection-management CLI used by ops
    ## + by the user-session activation layer to bring up specific
    ## connection profiles declaratively. NDE-K1 v1 manifest
    ## activations shell out to nmcli for connection-profile install.
    ## v1 records the artifact only.
    discard

  library libNm:
    ## ``libnm.so`` — the C library every desktop network widget
    ## (sway's waybar network module, GNOME shell's top-bar network
    ## indicator, Plasma's system tray icon) links against to consume
    ## the NetworkManager D-Bus interface via the high-level
    ## ``NMClient`` / ``NMDevice`` / ``NMActiveConnection`` GObject
    ## types. The SONAME ``libnm`` is camelCased to ``libNm`` per the
    ## libAsound / libExpat / libGlib2 precedent of preserving the
    ## canonical ``lib`` prefix while PascalCasing the SONAME body.
    ## v1 records the artifact only.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `autotools_package(...)` constructor.
    setCurrentOwningPackageOverride("networkManagerSource")
    try:
      let opts = @[
        "--disable-static",
        "--disable-tests",
        "--disable-introspection",
        "--without-docs",
        "--without-systemd-journal",
        "--with-modify-system=true",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("nmDaemon")
      discard pkg.executable("nmcli")
      discard pkg.library("libNm")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard

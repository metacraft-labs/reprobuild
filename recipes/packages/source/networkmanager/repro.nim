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
## NetworkManager 1.56 builds with Meson. The c_cpp_meson convention
## reads the M9.H ``fetch:`` block and the inlined Meson options and
## lowers them into fetch + setup + compile + install BuildActions;
## the per-artifact build body + install glue records the
## executable + executable + library artifacts via the two
## ``executable`` + one ``library`` blocks so the artifact
## registry already knows what binaries + shared object to expect.
##
## ## Artifacts
##
## NetworkManager's Meson build emits a vast set of binaries +
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
## v1 ships NO configurables — the Meson options are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * tests, docs, manpages, introspection, Vala, Qt, NMTUI, PPP,
##     ModemManager, OVS, cloud setup, SELinux, audit, and connectivity
##     checking are disabled to keep the initial daemon closure focused.
##   * systemd session tracking, udev discovery, Wi-Fi, the internal
##     DHCP client, D-Bus, and polkit remain enabled for desktop use.
##   * GnuTLS is selected instead of the default NSS crypto backend so
##     the package consumes the sibling source-built TLS stack.

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
  ## Tier-2b c_cpp_meson convention consumer: the convention
  ## layer reads the ``fetch:`` block (registered via
  ## ``registeredFetchSpec``) and the inlined Meson options and lowers
  ## them into fetch + setup + compile + install BuildActions. Two-executable +
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
    ## Meson is NetworkManager 1.56's only supported build system.
    "meson >=0.56"
    ## Ninja is Meson's build backend.
    "ninja >=1.10"
    ## gcc is the host C toolchain — NetworkManager is C11 with light
    ## use of GNU extensions.
    "gcc >=11"
    ## pkg-config probes the GLib, libuuid, D-Bus, libndp, udev,
    ## polkit, and GnuTLS inputs.
    "pkg-config"
    ## Meson runs NetworkManager's export and code-generation scripts.
    "perl >=5.32"

  buildDeps:
    ## glib2 supplies ``libglib-2.0`` + ``libgobject-2.0`` +
    ## ``libgio-2.0`` — NetworkManager's main loop integrates with
    ## GMainLoop and the NMClient / NMDevice public API are GObject
    ## types.
    "glib2 >=2.62"
    ## util-linux supplies ``libuuid`` for the per-connection UUID
    ## generation NetworkManager uses to key system-connection
    ## profiles.
    "util-linux >=2.36"
    ## dbus supplies ``libdbus-1`` — NetworkManager's D-Bus interface
    ## is the primary client API every desktop widget consumes.
    "dbus >=1.12"
    ## libndp provides IPv6 Neighbor Discovery handling.
    "libndp >=1.8"
    ## GnuTLS handles certificate and key operations.
    "gnutls >=3.7"
    ## systemd supplies ``libudev`` for netlink + udev device
    ## enumeration (the wired / wireless / Bluetooth interface probe).
    "systemd >=240"
    ## polkit authorizes privileged connection changes over D-Bus.
    "polkit >=0.120"
    ## GNU Readline provides nmcli's interactive line editor.
    "readline >=8.0"

  config:
    ## No prefix lifted from `mesonOptions:`; options are inlined below.
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
    ## artifact only; the Meson install tree is staged via an explicit
    ## alias from the upstream binary name.
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
    ## NetworkManager 1.56 ships Meson metadata and no configure script.
    setCurrentOwningPackageOverride("networkManagerSource")
    try:
      let opts = @[
        "default_library=shared",
        "tests=no",
        "introspection=false",
        "vapi=false",
        "docs=false",
        "man=false",
        "systemd_journal=false",
        "config_logging_backend_default=syslog",
        "session_tracking=systemd",
        "suspend_resume=systemd",
        "polkit=true",
        "modify_system=true",
        "selinux=false",
        "libaudit=no",
        "crypto=gnutls",
        "concheck=false",
        "libpsl=false",
        "ppp=false",
        "modem_manager=false",
        "ovs=false",
        "nmtui=false",
        "nm_cloud_setup=false",
        "firewalld_zone=false",
        "ifupdown=false",
        "nbft=false",
        "qt=false",
        "readline=libreadline",
      ]
      let patches = @[
        "sed -i 's/i18n.merge_file(/configure_file(/; s/    po_dir: po_dir,/    copy: true,/' src/data/meson.build",
      ]
      let pkg = meson_package(
        srcDir = "./src",
        configureOptions = opts,
        srcPatches = patches)
      discard pkg.executableAlias("nmDaemon", sourceName = "NetworkManager")
      discard pkg.executable("nmcli")
      discard pkg.library("libNm")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## Keep the daemon, client, and libnm closure explicit so the image
    ## resolves these libraries from source-built package mirrors.
    "glib2 >=2.62"
    "libndp >=1.8"
    "gnutls >=3.7"
    "systemd >=240"
    "dbus >=1.12"
    "polkit >=0.120"
    "readline >=8.0"

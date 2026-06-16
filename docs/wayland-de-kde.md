# DE-K1: KDE Plasma on ReproOS (Wayland-DEs PoC - Phase DE-K)

**Status.** DE-K1 architecture decision - Phase DE-K of the
[`ReproOS-Wayland-DEs-PoC`](../../reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org)
campaign. Companion to
[`wayland-de-hyprland.md`](wayland-de-hyprland.md) (DE-H1) and
[`wayland-de-gnome.md`](wayland-de-gnome.md) (DE-G1).

This is a PoC-scoped architecture document. Production-breadth concerns
(NetworkManager / Bluedevil / KAccounts integration, baloo file
indexer, klipper clipboard manager, KWalletManager seeding,
KScreenLocker session-bus wiring, plasma-discover updater, plasma-pa
audio applet) are called out as post-PoC follow-ups but not implemented
in this milestone.

* DE-K2 - vm-harness Hyper-V Plasma boot test (consumes the rootfs
  layout decided here).
* DE-H1 / DE-G1 - parallel Hyprland / GNOME architecture docs.
* DEM - Multi-DE composition (single ISO + GRUB / login-time selection).

## Summary of decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Plasma version | **Plasma 5.24 LTS (jammy-native)** | Ubuntu 22.04 LTS shipped Plasma 5.24.x via `plasma-desktop`, `plasma-workspace`, `kwin`, KF5 5.92, Qt 5.15.3. Backporting Plasma 6 to jammy would need Qt 6.5+ which jammy does not ship (jammy peaks at qt6-base 6.2). The DE-G2 sub-agent's recommendation: substitute to Plasma 5.24 LTS - same pattern as DE-H1's hyprland-to-sway. Future "DE-K-build-plasma6-from-source" milestone deferred. |
| Qt toolkit | **Qt 5.15.3 (jammy-native)** | Plasma 5.24 is a Qt 5 product. Shipping Qt 6 alongside would balloon the closure by ~70 MB extracted (libQt6Core/Gui/Widgets/Qml/Quick + qtwayland6 + qtdeclarative6); no benefit since no DE-K1 binary links Qt 6. The aggressive cap rules out Qt 6. |
| Display manager | **SDDM 0.19.0 (jammy)** | `sddm 0.19.0-2ubuntu2.3` is the LTS bug-fix build. Native Wayland-mode support via `[General] DisplayServer=wayland`. Autologin via `/etc/sddm.conf` `[Autologin]` section. Pairs naturally with the `sddm-theme-breeze` Plasma-branded greeter (planted but bypassed at runtime by autologin). |
| Compositor | **kwin_wayland** | KDE's compositor + window manager; shipped by `kwin-common` (binaries + libs) + `kwin-wayland` (Wayland-specific session helper). Same Wayland-IPC foundation as DE-H1's sway / DE-G1's mutter: links `libwayland-server.so.0`, `libxkbcommon.so.0`, `libdrm.so.2` from DE0-G. The KWin effects sub-libs (`libkwineffects.so.15`, `libkwinglutils.so.15`, `libkwinxrenderutils.so.13`, `libkwin4-effect-builtins.so.1`) live under `usr/lib/x86_64-linux-gnu/qt5/plugins/kwin/effects/` and `usr/lib/x86_64-linux-gnu/` respectively - the build script adds a dedicated ld.so.conf.d entry for the kwin plugin search root (mirrors DE-G1's `mutter-10/` sub-dir handling). |
| Shell | **plasmashell + krunner** | `plasmashell` (the desktop shell) is part of `plasma-workspace`; `krunner` (the launcher / search) is also in `plasma-workspace`. Both load KF5 frameworks via QML, so the `kf5-declarative` + `qml-modules` catalogs are non-optional. |
| Per-package store layout | `/opt/reproos-linux/store/<hash>/` (one subtree per catalog entry) | Matches DE0-G + DE-H1 + DE-G1 exactly. No new store-layout decision. |
| Closure source | Ubuntu jammy main + universe `.deb`s | Same machinery as DE0-G + DE-H1 + DE-G1. `.deb` closure ~62 MB compressed (~190 MB extracted) - the largest single-DE closure of the three. |
| Auto-login user | **repro:1000** (provisioned by DE0-S) | SDDM reads `/etc/sddm.conf`; the DE0-S session foundation already creates `repro:1000`. No new user-management work in DE-K1. |
| Session entry point | `/usr/local/bin/repro-start-plasma.sh` (shim) | Mirrors DE-H1's `repro-start-hyprland.sh` and DE-G1's `repro-start-gnome.sh`. Sources DE0-S session env, honours `REPRO_HEADLESS=1` (drives `QT_QPA_PLATFORM=minimal` + `KWIN_COMPOSE=O2`), and execs `startplasma-wayland`. |
| Wayland-session desktop file | `/etc/wayland-sessions/plasmawayland.desktop` | Plants the desktop file under the standard Plasma name so SDDM lists it. The `Exec=` line invokes `/usr/local/bin/repro-start-plasma.sh`. |
| Closure size budget | **~190 MB extracted** on top of DE0-G | plasma-workspace 11.8 MB compressed (the single largest .deb in the DE-K1 closure - ships plasmashell + krunner + kioslave5 + kcminit + the lockscreen + the panel + 12 helper libs), plasma-desktop-data 6.08 MB (icons + wallpapers + l10n), breeze 6.87 MB (themes + Breeze widget style + Breeze QtQuick controls), oxygen-sounds 1.89 MB, plasma-desktop 1.24 MB, libkf5widgetsaddons-data 1.20 MB, libkf5i18n-data 1.21 MB, balance ~30 MB across 86 other .debs. Within the spec's 3 GB Plasma-6 budget by 16x (Plasma 5 is materially smaller). |
| Audio stack | **PipeWire 0.3.48 (client lib only, daemon NOT planted)** | Plasma 5 + xdg-desktop-portal-kde DT_NEEDED `libpipewire-0.3.so.0` from DE-G1's `libpipewire.json` catalog (already in the shared closure). The PipeWire **daemon** (`pipewire`, `pipewire-bin`, `wireplumber`) is NOT planted: socket-activated user units require lingering enabled + a UID-1000 session that DE-K2 hasn't validated for VM-with-no-audio-device. xdg-desktop-portal-kde's screencast portal fails open when no PipeWire daemon is reachable; acceptable per PoC scope. **Future post-PoC**: add a `pipewire-stack.json` catalog with the daemon + wireplumber user units. |
| QML module set | **Single `qml-modules.json` aggregator** | Plasma 5.24's `plasmashell` + `kwin_wayland` + the KF5 declarative bridge load 17 QML modules at startup: qtquick2/-window2/-layouts/-controls/-controls2/-templates2/-dialogs + qt-labs-{folderlistmodel,settings} + org.kde.{kirigami2,kquickcontrols,kquickcontrolsaddons,kwindowsystem,kcoreaddons,solid,draganddrop}. Each is a separate .deb in jammy; bundling them all into one catalog keeps the entry count under the 30 budget. |
| KF5 framework consolidation | **Five mega-catalogs** | 50+ libkf5*.deb files exist in jammy. To stay within the 30-catalog cap, we group: `kf5-core.json` (kauth/kconfig/kcoreaddons/kcrash/karchive/kcodecs/kdbusaddons), `kf5-gui.json` (kwidgetsaddons/kguiaddons/kitemviews/kjobwidgets/kiconthemes/kcompletion/ki18n), `kf5-frameworks.json` (kwindowsystem/kglobalaccel/kxmlgui/knotifications/knotifyconfig/kservice/kcmutils/kpackage/sonnet), `kf5-declarative.json` (kdeclarative + kquickaddons), `kf5-extras.json` (solid/baloo/kaccounts). Same packaging precedent as `gdm.json` (gdm3 + libgdm1) and DE-H1's `sway.json` (sway + swaybg). |
| Qt 5 consolidation | **Three mega-catalogs** | Qt 5 jammy ships ~30 `libqt5*` debs; the DE-K1-reachable subset is 21 of them. We bundle: `qt5-base.json` (libqt5{core5a,gui5,widgets5,network5,dbus5,xml5,sql5,concurrent5,x11extras5,opengl5}), `qt5-declarative.json` (libqt5{qml5,quick5,quickwidgets5,quicktemplates2-5,quickparticles5,quickshapes5,quicktest5}), `qt5-wayland.json` (qtwayland5 + libqt5waylandclient5 + libqt5waylandcompositor5). `qt5-svg.json` (single .deb) stays separate because it's the only .deb from the qtsvg-opensource-src source package. |

## Why Plasma 5.24 (not Plasma 6)

The campaign-section prose said "KDE Plasma 6 on ReproOS". Empirical reality:

- `apt-cache show plasma-desktop` on the harvest distro `repro-ubuntu`
  (jammy 22.04.5 LTS): version **5.24.7-0ubuntu0.1**, available in jammy
  universe. Plasma 6 is **not present** in any official jammy pocket.
- Qt 6 in jammy: peaks at **6.2.4** (universe). Plasma 6 requires **Qt
  6.5+** for `kf6-frameworks` and Plasma 6 core libs.
- A from-source Plasma 6 build would need: meson/cmake newer than jammy's
  (cmake 3.22 vs 3.25+), Qt 6.5+ (build cascade: ~80 build-deps), KF6
  from-source (~50 frameworks), and KWin 6's Vulkan rendering backend
  (Vulkan 1.3 headers vs jammy's 1.2). The chain has ~200+ explicit
  build-deps to backport individually.

DE-K1's gate is the architecture doc + catalog + builder + integration
test. **A from-source Plasma 6 build is correctly scoped to a future
milestone "DE-K-build-plasma6-from-source" that does not block DE-K1.**

Plasma 5.24 is the correct PoC anchor because:

1. **Jammy-native.** Every catalog entry is one `apt-get download` away.
   ABI-compatible with DE0-G's Mesa 23.2.1 + DE-H1's libxkbcommon 1.4.0,
   libfontconfig 2.13, libwayland 1.20.
2. **Same Wayland foundation.** Plasma 5.24's kwin_wayland is the first
   release where Wayland is co-equal with the X11 backend (not
   experimental). Architecturally identical to Plasma 6 from the
   Wayland-IPC point of view (same `wl_display`, `wl_registry`,
   `xdg-shell`, `wlr-output-management`, `kde-wm-base` protocols).
3. **Smallest viable Plasma closure.** Plasma 6 pulls in qt6-base + qt6-
   declarative + qt6-wayland + qt6-svg (~70 MB extracted on top of
   anything), KF6 (parallel to KF5; +30 MB), and kwin 6's Vulkan
   backend. Plasma 5.24's closure is ~190 MB extracted; Plasma 6 would be
   ~290 MB - well above the PoC "as-small-as-possible" preference even
   though both fit the 3 GB campaign budget.
4. **Documented upgrade path.** When jammy -> noble bump happens
   (post-PoC), the catalog entries flip version-pins to Plasma 5.27 LTS
   (noble universe) or to Plasma 6 (noble main); the build script +
   integration test are unchanged.

## NixOS reference architecture

NixOS reference modules consulted for the DE-K1 closure list and
service ordering:

- `nixos/modules/services/desktop-managers/plasma6.nix` - canonical
  Plasma 6 enablement module. Acknowledged but NOT followed: DE-K1
  ships Plasma 5.24 per the rationale above. The dependency closure
  shape (kwin + plasma-workspace + plasma-desktop + breeze + KF5
  frameworks + Qt 5/6 base) maps 1:1 to Plasma 5 with the framework
  versions stepped back.
- `nixos/modules/services/desktop-managers/plasma5.nix` - the direct
  upstream reference (still present in nixpkgs at the time of writing).
  Pulls in `plasma-workspace`, `kwin`, `plasma-desktop`,
  `kde-cli-tools`, `kdelibs4support`, `breeze`, `plasma-integration`,
  `xdg-desktop-portal-kde`, KF5 frameworks (the full 50+ libraries),
  Qt 5 base + declarative + wayland + svg.
- `nixos/modules/services/x11/display-managers/sddm.nix` - SDDM
  configuration: autoLogin, autoNumlock, theme selection. The
  `display-manager.service` is a symlink to `sddm.service`.
- `nixos/modules/services/desktop-managers/none.nix` - minimal
  graphical-session.target setup the PoC mirrors.

The PoC does NOT re-implement nix or invoke nixpkgs at runtime; it reads
these modules for the canonical dependency closure, then re-implements
the equivalent as a `recipes/catalog/linux/` tier (parallel to DE0-G +
DE-H1 + DE-G1).

## Closure

Per-package planted artefacts for DE-K1 (on top of DE0-G base; DE-H1
and DE-G1 are independent overlays that compose without conflict):

| Catalog | Primary .deb(s) | Version | .deb size | Role |
|---------|-----------------|---------|-----------|------|
| `sddm.json` | `sddm` | 0.19.0-2ubuntu2.3 | 648 KB | Simple Desktop Display Manager. Ships `/usr/bin/sddm` + `/usr/bin/sddm-greeter` + `lib/systemd/system/sddm.service` + 3 PAM stacks (`/etc/pam.d/sddm{,-autologin,-greeter}`). |
| `kwin.json` | `kwin-common` + `kwin-wayland` | 5.24.7-0ubuntu0.2 | 2.45 MB | KWin Wayland compositor + base. `kwin-common` ships `/usr/bin/kwin_wayland` + `/usr/bin/kwin_x11` + ~25 plugin .so files under `qt5/plugins/kwin/`. `kwin-wayland` ships the Wayland-specific session helper + greeter integration. |
| `kwin-libs.json` | `libkwineffects15` + `libkwinglutils15` + `libkwinxrenderutils13` + `libkwin4-effect-builtins1` + `libkdecorations2-5v5` + `libkdecorations2private8v5` | 5.24.7-0ubuntu0.2 + 5.24.4-0ubuntu1 | 219 KB | KWin effect / decoration helper libs. `libkwineffects.so.15` is the effects API; `libkwinglutils.so.15` wraps the GL helper; `libkwinxrenderutils.so.13` is the legacy X-Render helper (kept for kwin_x11 fallback path); `libkwin4-effect-builtins.so.1` ships the built-in effects (blur, sheet, slide); `libkdecorations2-5v5` is the legacy decoration API; `libkdecorations2private8v5` is the private/internal companion lib. |
| `plasma-workspace.json` | `plasma-workspace` + `plasma-workspace-wayland` + `libplasma-geolocation-interface5` + `libtaskmanager6` + `libnotificationmanager1` + `libkworkspace5-5` + `sddm-theme-breeze` | 5.24.7-0ubuntu0.2 | ~12.99 MB | Plasma workspace: `/usr/bin/plasmashell` + `/usr/bin/krunner` + `/usr/bin/kcminit` + `/usr/bin/ksmserver` + `/usr/bin/startplasma-wayland` + 23 helper binaries under `usr/libexec/`. The `-wayland` deb ships the Wayland-specific session entry; the four lib*.debs ship runtime-only helper libs. `sddm-theme-breeze` is the Breeze-branded SDDM greeter theme (bypassed at runtime by autologin but planted for completeness). |
| `plasma-desktop.json` | `plasma-desktop` + `plasma-desktop-data` | 5.24.7-0ubuntu0.1 | 7.32 MB | Plasma desktop session glue: `/usr/bin/plasma-changeicons` + `/usr/bin/lookandfeeltool` + 12 sub-utilities. The `-data` deb ships `/usr/share/plasma/desktoptheme/` (5 theme variants), `/usr/share/wallpapers/`, the l10n files. |
| `plasma-framework.json` | `plasma-framework` + `libkf5plasma5` + `libkf5plasmaquick5` | 5.92.0-0ubuntu1 | 3.14 MB | KF5 Plasma framework + its QtQuick bridge. `libkf5plasma5.so.5` is the C++ Plasma API (panels, applets); `libkf5plasmaquick5.so.5` exposes it to QML. `plasma-framework` ships shared assets `/usr/share/plasma/`. |
| `plasma-integration.json` | `plasma-integration` + `polkit-kde-agent-1` | 5.24.4-0ubuntu1 | 223 KB | Qt 5 platform-theme plugin for Plasma + the Polkit authentication agent shipped as `/usr/lib/x86_64-linux-gnu/libexec/polkit-kde-authentication-agent-1`. |
| `kactivities.json` | `kactivitymanagerd` + `libkf5activities5` | 5.24.4-0ubuntu1 + 5.92.0-0ubuntu1 | 276 KB | KDE Activities daemon + KF5 activities client lib. Plasma 5 requires `kactivitymanagerd` running on the session bus for the desktop's "activity" switching even when only the default activity is used. |
| `breeze.json` | `breeze` + `breeze-cursor-theme` | 5.24.7-0ubuntu0.2 | 7.19 MB | Breeze widget style + window decoration theme + cursor theme. Single largest .deb in the DE-K1 catalog by extracted size (icon themes + decoration assets). |
| `kf5-core.json` | `libkf5coreaddons5` + `-data` + `libkf5configcore5` + `libkf5configgui5` + `libkf5configwidgets5` + `-data` + `libkf5config-data` + `libkf5dbusaddons5` + `-data` + `libkf5authcore5` + `libkf5auth-data` + `libkf5crash5` + `libkf5archive5` + `libkf5codecs5` + `-data` | 5.92.0-0ubuntu1 | 1.41 MB | KF5 core frameworks (KAuth + KCodecs + KConfig + KCoreAddons + KCrash + KDBusAddons + KArchive). 15 .debs aggregated. |
| `kf5-gui.json` | `libkf5guiaddons5` + `-bin` + `-data` + `libkf5widgetsaddons5` + `-data` + `libkf5itemviews5` + `libkf5jobwidgets5` + `libkf5iconthemes5` + `-data` + `libkf5completion5` + `-data` + `libkf5i18n5` + `-data` | 5.92.0-0ubuntu1 / -0ubuntu2 | 3.55 MB | KF5 GUI helper frameworks (KGuiAddons + KWidgetsAddons + KItemViews + KJobWidgets + KIconThemes + KCompletion + KI18n). 13 .debs aggregated. KI18n data is the second-largest single .deb in DE-K1 (1.21 MB compressed: l10n catalogs for 60+ locales). |
| `kf5-frameworks.json` | `libkf5windowsystem5` + `-data` + `libkf5globalaccel5` + `-bin` + `-data` + `libkf5globalaccelprivate5` + `libkf5xmlgui5` + `-data` + `-bin` + `libkf5notifications5` + `-data` + `libkf5notifyconfig5` + `-data` + `libkf5service5` + `-bin` + `-data` + `libkf5kcmutils5` + `libkf5package5` + `-data` + `libkf5sonnetcore5` + `libkf5sonnetui5` + `libkf5sonnet5-data` | 5.92.0-0ubuntu1 / -0ubuntu2 | 2.42 MB | KF5 desktop-tier frameworks (KWindowSystem + KGlobalAccel + KXmlGui + KNotifications + KNotifyConfig + KService + KCMUtils + KPackage + Sonnet). 22 .debs aggregated. |
| `kf5-declarative.json` | `libkf5declarative5` + `libkf5quickaddons5` | 5.92.0-0ubuntu1 | 69 KB | KF5 QML bridge (KDeclarative + KQuickAddons). Required by plasmashell + krunner for their QML UI. |
| `kf5-runner.json` | `libkf5runner5` | 5.92.0-0ubuntu1 | 90 KB | KF5 Runner API (the krunner search-result plugin interface). |
| `kf5-newstuff.json` | `libkf5newstuff5` + `libkf5newstuffcore5` + `libkf5newstuff-data` | 5.92.0-0ubuntu1.1 | 801 KB | KF5 KNewStuff (the "Get Hot New Stuff" plugin system). Hard-deped by plasma-workspace's wallpaper picker. |
| `kio.json` | `kio` + `libkf5kiocore5` + `libkf5kiogui5` + `libkf5kiowidgets5` + `libkf5kiofilewidgets5` + `libkf5kiontlm5` + `libkf5bookmarks5` + `libkf5parts5` | 5.92.0-0ubuntu1 | 5.32 MB | KIO virtual-filesystem framework + 5 client libs + KBookmarks + KParts. plasma-workspace's plasmashell hard-deps `libKF5KIOCore.so.5` for its "open file" dialog. The `kio` .deb itself ships the kioslave5 helper executables (`/usr/lib/x86_64-linux-gnu/libexec/kf5/kioslave5`). |
| `kded.json` | `kded5` + `kpackagetool5` + `kde-cli-tools` | 5.92.0-0ubuntu1 + 5.24.4-0ubuntu1 | 276 KB | KDED5 (the desktop-bus daemon used by kactivitymanagerd, plasmashell's KSysGuard module, KIO scheduler). `kpackagetool5` (the CLI for KPackage). `kde-cli-tools` (kcmshell5 + kdesu5 + kioclient5 + kstart5). |
| `kdelibs4support.json` | `libkf5kdelibs4support5` | 5.92.0-0ubuntu1 | 796 KB | KDELibs 4 -> KF5 transition shim. Hard-deped by plasma-desktop for legacy KGlobal::config() / KConfigGroup global access. Single largest non-`-data` .deb in the KF5 aggregation. |
| `kf5-extras.json` | `libkf5solid5` + `-data` + `libkf5baloo5` + `libkaccounts2` | 5.92.0-0ubuntu1 + 21.12.3 | 446 KB | KF5 Solid (hardware abstraction) + KBaloo (file indexer client lib; the indexer daemon itself is NOT planted) + KAccounts (account integration framework client lib; no daemon). |
| `qt5-base.json` | `libqt5core5a` + `libqt5gui5` + `libqt5widgets5` + `libqt5network5` + `libqt5dbus5` + `libqt5xml5` + `libqt5sql5` + `libqt5concurrent5` + `libqt5x11extras5` + `libqt5opengl5` | 5.15.3+dfsg-2ubuntu0.2 + 5.15.3-1 | 9.69 MB | Qt 5.15.3 base libraries from the `qtbase-opensource-src` source package + qtx11extras. 10 .debs aggregated. `libqt5gui5` 3.72 MB is the single largest Qt 5 .deb (ships the platform plugin loader + the QPA backends `xcb`, `wayland`, `minimal`, `offscreen`). |
| `qt5-declarative.json` | `libqt5qml5` + `libqt5quick5` + `libqt5quickwidgets5` + `libqt5quicktemplates2-5` + `libqt5quickparticles5` + `libqt5quickshapes5` + `libqt5quicktest5` | 5.15.3+dfsg-1 | 4.10 MB | Qt 5 Declarative (QML + Quick) - the runtime of every Plasma UI. Plasma's plasmashell + krunner + plasma-discover are all QML apps. |
| `qt5-wayland.json` | `qtwayland5` + `libqt5waylandclient5` + `libqt5waylandcompositor5` | 5.15.3-1 | 1.04 MB | Qt 5 Wayland integration. `libQt5WaylandClient.so.5` is the wl_compositor-side Qt platform plugin client; `libQt5WaylandCompositor.so.5` is the compositor-side API used by kwin_wayland to host Qt-on-Wayland surfaces. The `qtwayland5` .deb ships the QPA plugin `wayland.so` under `qt5/plugins/platforms/`. |
| `qt5-svg.json` | `libqt5svg5` | 5.15.3-1 | 149 KB | Qt 5 SVG renderer. Loaded by KIconThemes + by Plasma's QML SVG decorations. |
| `qml-modules.json` | 17 `qml-module-*` .debs (qtquick2 + qtquick-window2 + qtquick-layouts + qtquick-controls + qtquick-controls2 + qtquick-templates2 + qtquick-dialogs + qt-labs-folderlistmodel + qt-labs-settings + org.kde.{kirigami2, kquickcontrols, kquickcontrolsaddons, kwindowsystem, kcoreaddons, solid, draganddrop}) | 5.15.3+dfsg-1 / 5.92.0-0ubuntu{1,2} | 2.71 MB | All QML modules loaded by plasmashell / krunner / kwin's QML scripts. Each .deb ships a `qml/<module>/qmldir` + `lib*.so` plugin. Aggregated into one catalog to stay under the 30-catalog cap (DE-G1 used the same "aggregator" pattern for gsettings + adwaita data). |
| `phonon.json` | `phonon4qt5` + `libphonon4qt5-4` | 4.11.1-4 | 159 KB | Phonon 4 (Qt 5 binding). Plasma's notification daemon + media controls. The phonon backend (gstreamer / vlc) is NOT planted; phonon falls back to its null backend at runtime - notifications work silently. |
| `xdg-desktop-portal-kde.json` | `xdg-desktop-portal-kde` | 5.24.7-0ubuntu0.1 | 199 KB | KDE backend for `xdg-desktop-portal`. Forwards file-chooser / screenshot / screencast requests to KWin + plasmashell. The portal daemon (shipped by DE-H1's `xdg-desktop-portal.json` catalog when present) routes to this backend when the active DE is Plasma. |
| `libkscreenlocker.json` | `libkscreenlocker5` | 5.24.4-0ubuntu1 | 107 KB | KScreenLocker shared library. Loaded by plasma-workspace's screen-lock dispatch. The lock-screen UI binary `kscreenlocker_greet` is also shipped (under `usr/libexec/`). |
| `libksysguard.json` | `libksgrd9` + `libksignalplotter9` + `libprocesscore9` + `libprocessui9` + `libkf5sysguard-bin` | 5.24.6-0ubuntu0.2 | 344 KB | KSysGuard libs (the system monitor's data sources, the signal-plot widget, and the process tree). plasma-workspace's plasma-systemmonitor applet links them. |
| `libxcb-extras-kde.json` | `libxcb-keysyms1` + `libxcb-record0` + `libxcb-cursor0` + `libxcb-image0` + `libxcb-icccm4` + `libxcb-util1` + `libxcb-randr0` + `libxcb-render0` + `libxcb-render-util0` + `libxcb-shape0` | 0.4.0 / 1.14 / 0.3.9 / 0.1.1 / 0.4.1 | 110 KB | XCB extras specifically required by kwin_x11 fallback path + Qt5 XCB QPA plugin. These are NOT in DE-H1's `libxcb-extras.json` (which targeted wlroots-style compositors and ships a subset). |
| `oxygen-sounds.json` | `oxygen-sounds` + `libkuserfeedbackcore1` + `libpackagekitqt5-1` + `libpolkit-qt5-1-1` | 5.24.6-0ubuntu0.1 + 1.2.0-2 + 1.0.2-1 + 0.114.0-2 | 2.17 MB | Plasma audio assets (Oxygen sound theme - notification chimes) + 3 small client libraries that plasma-desktop hard-deps but are too small to warrant their own catalogs: KUserFeedback (telemetry, opt-out via env), PackageKit Qt 5 binding (offered updates dialog), Polkit-Qt 5 binding (used by polkit-kde-authentication-agent-1). |

Total `.deb` closure added by DE-K1: **~62 MB compressed** (~190 MB
extracted). Combined DE0-G + DE-K1 extracted footprint: ~310 MB.
Spec's "~2.5 GB" budget includes the full Plasma 6 + qt6 stack we did
NOT ship - acceptable for a headless PoC.

## Layout schema

The single overlay tree DE-K1 produces (on top of DE0-G base):

```
ReproOS rootfs (DE-K1 additions on top of DE0-S + DE0-D + DE0-G base)
======================================================================

  /opt/reproos-linux/store/                   Existing DE0-G store; DE-K1
                                              adds 30 new subtrees.
    <sddm-hash>/
      etc/pam.d/sddm
      etc/pam.d/sddm-autologin
      etc/pam.d/sddm-greeter
      etc/dbus-1/system.d/org.freedesktop.DisplayManager.conf
      lib/systemd/system/sddm.service
      usr/bin/sddm
      usr/bin/sddm-greeter
    <kwin-hash>/
      usr/bin/kwin_wayland
      usr/bin/kwin_x11
      usr/bin/kwin_wayland_wrapper
      usr/lib/x86_64-linux-gnu/qt5/plugins/kwin/...    (plugin tree)
    <plasma-workspace-hash>/
      usr/bin/plasmashell
      usr/bin/krunner
      usr/bin/kcminit
      usr/bin/ksmserver
      usr/bin/startplasma-wayland
      usr/lib/x86_64-linux-gnu/libtaskmanager.so.6.0
      usr/lib/x86_64-linux-gnu/libnotificationmanager.so.1.0
      usr/lib/x86_64-linux-gnu/libkworkspace5.so.5.24.7
      usr/lib/x86_64-linux-gnu/libplasma-geolocation-interface.so.5.24.7
      usr/share/sddm/themes/breeze/                     (from sddm-theme-breeze)
    ... (27 more subtrees follow the same shape) ...

    registry.json                             DE-K1 appends its 30 entries
                                              (sorted by name).

  /etc/ld.so.conf.d/00-reproos-linux.conf     Existing DE0-G snippet;
                                              DE-K1 appends each new
                                              store-dir's lib path
                                              (including the
                                              qt5/plugins/kwin/ sub-dir
                                              parallel to DE-G1's
                                              mutter-10/).

  /etc/sddm.conf                              NEW. [General]
                                              DisplayServer=wayland;
                                              [Autologin] User=repro,
                                              Session=plasmawayland.

  /etc/wayland-sessions/plasmawayland.desktop NEW. Wayland session file
                                              SDDM sees.
                                              Exec=/usr/local/bin/repro-start-plasma.sh.

  /usr/local/bin/repro-start-plasma.sh        NEW. Session entry shim;
                                              sources DE0-S session env,
                                              honours REPRO_HEADLESS,
                                              execs startplasma-wayland.

  /etc/systemd/system/multi-user.target.wants/sddm.service
                                              NEW symlink ->
                                              /opt/reproos-linux/store/
                                              <sddm-hash>/lib/systemd/
                                              system/sddm.service.
                                              Activates SDDM at
                                              multi-user.target for the
                                              PoC (graphical.target is
                                              the production target).
  /etc/systemd/system/display-manager.service NEW symlink -> same target
                                              (Plasma convention; many
                                              KDE components check the
                                              display-manager.service
                                              symlink existence).

  /etc/profile.d/plasma-qt.sh                 NEW. Exports QT_PLUGIN_PATH
                                              + QML2_IMPORT_PATH +
                                              KDE_FULL_SESSION + XDG_*
                                              so Qt finds the planted
                                              QPA plugin tree and KF5
                                              finds the planted QML
                                              modules.

  /var/lib/reproos-de-plasma-done             NEW. Sentinel for idempotent
                                              re-apply (mirrors
                                              /var/lib/reproos-de-{hyprland,gnome}-done).
```

## DE-G1 / DE-H1 cascade lessons inherited

These cascade lessons land as known pattern requirements; DE-K1's
builder implements them by reference, not by re-discovery:

1. **`/etc/profile.d/reproos-libpath.sh` planting (cascade E).** R9's
   from-source initramfs ships NO `ldconfig` and NO `ld.so.cache`
   builder. Without a cache, the dynamic linker IGNORES
   `/etc/ld.so.conf.d/*.conf` entries entirely. DE-H1 worked around this
   by exporting `LD_LIBRARY_PATH` from the same per-catalog libdirs that
   landed in `00-reproos-linux.conf`. DE-K1 appends its lib paths to the
   same env-export file (the DE-H1/DE-G1 builder already wrote one;
   DE-K1's builder UPDATES it after planting).

2. **`/etc/profile` splice for `/etc/profile.d/*.sh` sourcing (cascade E).**
   R9's `/etc/profile` is a 4-line static export and does NOT source
   `/etc/profile.d/*.sh`. DE-H1 spliced in a sourcing block;
   DE-K1 idempotently checks the marker and SKIPS if already spliced.

3. **`/usr/local/bin/<name>` symlink farm for autologin shell PATH
   (cascade B).** Binaries under `/opt/reproos-linux/store/<hash>/usr/bin/`
   need a `/usr/local/bin/<name>` symlink so the autologin shell finds
   them on PATH. DE-K1 plants symlinks for `sddm`, `sddm-greeter`,
   `kwin_wayland`, `kwin_x11`, `plasmashell`, `krunner`, `kcminit`,
   `ksmserver`, `startplasma-wayland`, `kded5`, `kpackagetool5`. The
   `kioslave5` helper lives under `usr/lib/x86_64-linux-gnu/libexec/kf5/`
   and is PATH-private per KIO convention (NOT symlinked).

4. **Qt plugin tree handling (NEW for DE-K1; parallel to DE-G1's
   mutter-10/ sub-dir).** Qt 5's QPA plugins live under
   `usr/lib/x86_64-linux-gnu/qt5/plugins/<category>/`; KWin's plugins
   live under `usr/lib/x86_64-linux-gnu/qt5/plugins/kwin/`. The builder
   adds dedicated ld.so.conf.d entries for each store-dir's `qt5/plugins`
   tree AND exports `QT_PLUGIN_PATH` from `/etc/profile.d/plasma-qt.sh`
   so Qt's plugin loader finds them. Same precedent as DE-G1's
   `mutter-10/` ld.so.conf.d handling.

5. **QML import tree handling (NEW for DE-K1).** Qt 5's QML modules
   live under `usr/lib/x86_64-linux-gnu/qt5/qml/<dotted.module>/`. The
   builder concatenates each store-dir's `qt5/qml/` path into a single
   `QML2_IMPORT_PATH` colon-list exported by `plasma-qt.sh`. plasmashell
   + krunner walk this path at startup to resolve `import org.kde.*`.

6. **Sentinel + idempotency.** `/var/lib/reproos-de-plasma-done` mirrors
   the DE-G1/DE-H1 sentinels; re-running the builder is a no-op until
   the sentinel is removed.

## `/etc/sddm.conf` shape

```
[General]
DisplayServer=wayland
Numlock=on

[Autologin]
User=repro
Session=plasmawayland.desktop
Relogin=true

[Theme]
Current=breeze
CursorTheme=breeze_cursors

[Wayland]
CompositorCommand=/opt/reproos-linux/store/<kwin-hash>/usr/bin/kwin_wayland --no-lockscreen
```

Five knobs documented:

| Knob | Value | Effect |
|------|-------|--------|
| `DisplayServer=wayland` | force Wayland | Disables the X11 greeter path; kwin_wayland runs as the compositor for both greeter and session. |
| `[Autologin] User=repro` + `Session=plasmawayland.desktop` | autologin as repro | Skips the greeter UI entirely. DE0-S provisioned `repro:1000`. The session-file basename matches `/etc/wayland-sessions/plasmawayland.desktop`. |
| `Relogin=true` | re-trigger autologin on session exit | Prevents the greeter from popping after a session crash; the PoC test wants the same session to come back automatically. |
| `[Theme] Current=breeze` | Breeze greeter theme | Cosmetic only since autologin skips the greeter; planted for completeness. |
| `[Wayland] CompositorCommand=` | absolute path to kwin_wayland | Pins the Wayland compositor used for the greeter to the store-planted kwin (bypassing PATH-resolution which may fail before the user shell is up). The build script substitutes the actual store hash at apply time. |

## `/etc/wayland-sessions/plasmawayland.desktop` shape

```
[Desktop Entry]
Name=Plasma (Wayland)
Comment=ReproOS Plasma 5 Wayland session (DE-K1)
Exec=/usr/local/bin/repro-start-plasma.sh
TryExec=/usr/local/bin/startplasma-wayland
Type=Application
DesktopNames=KDE
```

`TryExec=` lets SDDM hide the session entry if the startplasma-wayland
binary isn't on PATH (defensive; the symlink-farm always plants it).

## Risks for DE-K2 (vm-harness boot test)

1. **Cascade G blocks the actual boot gate uniformly (same as DE-H2 /
   DE-G2).** The R9 systemd dbus.socket non-activation issue surfaced by
   DE-H2 will surface DE-K2 too. DE-K1 lands cleanly because it's
   catalog + builder work; DE-K2 is the gate that's actually affected.
   Documented in the memo as "DE-H2 cascade G OPEN".

2. **No Hyper-V SyntheticVideo support in kwin's DRM backend.** kwin
   5.24.7's DRM backend opens `/dev/dri/card0` via libdrm + libgbm, same
   as sway / mutter. The DE0-K kernel enables `CONFIG_DRM_HYPERV=y`
   which creates `card0`; the DRM allocator path through `libgbm.so.1`
   lands on the llvmpipe software rasterizer. Backup:
   `KWIN_COMPOSE=O2` + `QT_QPA_PLATFORM=offscreen` (already wired into
   the start shim under `REPRO_HEADLESS=1`) skips the DRM backend
   entirely and renders to an off-screen surface.

3. **plasmashell hard-deps kded5 + kactivitymanagerd on the session bus.**
   Both are session-bus daemons activated by xdg-autostart files
   (`/etc/xdg/autostart/`). DE-K1 ships both binaries + the autostart
   files; the start shim's `dbus-daemon --session --fork` line gives
   them a bus to register on. If DE-K2's autostart sequence misorders,
   plasmashell aborts with "Activities service unreachable" - the
   start shim defensively launches kactivitymanagerd + kded5 before
   exec'ing startplasma-wayland.

4. **xdg-desktop-portal-kde DT_NEEDED `libpipewire-0.3.so.0`.** DE-G1
   shipped this lib via `libpipewire.json`; DE-K1 reuses it via
   `dependency_closure[]`. If DE-K1 is enabled without DE-G1, the lib
   must still be present - the build script adds `libpipewire` to the
   DE-K1 closure independently (DE-G1's catalog is a SHARED catalog,
   not a DE-G1-only one).

5. **Qt 5's QPA plugin loader requires `QT_PLUGIN_PATH` set.** Without
   it, Qt searches only `$QTDIR/plugins` which is /usr/lib/qt5/plugins
   on a stock Ubuntu, NOT the per-store-hash paths the catalog tier
   plants under. The `plasma-qt.sh` profile.d script exports
   `QT_PLUGIN_PATH=` as a colon list of all the planted
   `qt5/plugins` dirs. **Failure mode:** if the autologin shell does
   not source `/etc/profile.d/*.sh` (cascade E lesson), QT_PLUGIN_PATH
   is unset, kwin_wayland exits with "QPA plugin not found".
   Mitigation: the repro-start-plasma.sh shim explicitly sources
   `/etc/profile.d/*.sh` before exec.

6. **plasma-workspace's `klauncher` is a session-bus auto-activated
   service.** kwin_wayland talks to klauncher to launch apps from the
   plasmashell run-dialog. If klauncher isn't reachable (no
   dbus-daemon), kwin_wayland logs warnings; the session continues but
   the run-dialog is non-functional. Acceptable per PoC scope (the
   integration test never exercises run-dialog).

7. **No real graphical-session.target wiring.** DE-K1 plants
   sddm.service into `multi-user.target.wants/`, not
   `graphical.target.wants/`. The R9 base does not bring up
   graphical.target; multi-user is the highest target it reaches.
   DE-K2 may need to flip this if the boot test asserts graphical.target
   activation.

8. **Symlink farm overlap with DE-G1 / DE-H1.** DE-K1 plants names
   `sddm`, `kwin_wayland`, `kwin_x11`, `plasmashell`, `krunner`,
   `startplasma-wayland`, `kcminit`, `ksmserver`, `kded5`,
   `kpackagetool5`, `kcmshell5`. None overlap with DE-H1 (`sway`,
   `foot`, `waybar`) or DE-G1 (`gnome-shell`, `gnome-session`,
   `mutter`, `gjs-console`, `gdm-screenshot`). When all three overlays
   compose into a multi-DE ISO (future DEM phase), no collision.

## Limitations (PoC scope)

- **No real graphical-session.target wiring.** Same as DE-G1; multi-user
  is the target the R9 base reaches.
- **No transitive dep walker.** Same precedent as DE0-G + DE-H1 + DE-G1:
  every catalog's `dependency_closure[]` is hand-curated and advisory.
- **No PipeWire daemon.** Only `libpipewire-0.3.so.0` (from DE-G1's
  catalog). Screencast + audio over portal will fail; acceptable per
  PoC scope.
- **No baloo file indexer daemon.** Only `libKF5Baloo.so.5` (client
  lib). plasmashell logs warnings about indexer unavailability and
  continues.
- **No NetworkManager / Bluedevil / KAccounts daemons.** plasmashell
  logs warnings and continues. No on-screen network indicator, no
  Bluetooth, no account sync.
- **No KWalletManager daemon.** Apps that hard-deps wallet for
  credentials get NULL secret-service responses; acceptable for the
  PoC's "kwin_wayland comes up" gate.
- **No GPU acceleration.** llvmpipe software rasterization only; kwin
  will be slow but functional under headless mode. Matches DE0-G's
  stance.
- **No theming customization.** Default Breeze (light); no custom
  shell theme, no custom Qt style override, no wallpaper.
- **No multi-arch.** amd64-only. Same as DE-H1 / DE-G1.
- **No signed envelopes.** Relies on `archive.ubuntu.com` over plain
  HTTP + sha256 pin. Matches DE-H1 / DE-G1 stance.
- **No Qt 6 / KF6.** Plasma 5.24 + Qt 5.15 only. Future
  "DE-K-build-plasma6-from-source" milestone is the upgrade path.

## Future migration path

When DE-K-build-plasma6-from-source builds upstream Plasma 6:

1. New catalog entries `recipes/catalog/linux/{plasma6-shell,kwin6,kf6-*}.json`
   with `provisioning_methods[].kind = "from-source"`.
2. The build script gains a conditional: if Plasma 6 catalogs are
   present, plant them instead of the jammy Plasma 5 .debs.
3. `/etc/sddm.conf` is unchanged.
4. `/etc/wayland-sessions/plasmawayland.desktop` is unchanged.
5. `repro-start-plasma.sh` execs the new `startplasma6-wayland` binary
   instead of `startplasma-wayland`; the env-export contracts are
   compatible.
6. The compositor swap is **invisible to the rest of the rootfs** - no
   wayland-session.desktop change, no PAM change, no D-Bus change, no
   ld.so.conf.d change. Validates that the DE0 foundation is correctly
   isolated from the compositor identity.

Same architecture-invariance property DE-H1 / DE-G1 established for
their respective compositor swaps.

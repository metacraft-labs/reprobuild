# DE-G1: GNOME on ReproOS (Wayland-DEs PoC — Phase DE-G)

**Status.** DE-G1 architecture decision — Phase DE-G of the
[`ReproOS-Wayland-DEs-PoC`](../../reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org)
campaign. Companion to [`wayland-de-hyprland.md`](wayland-de-hyprland.md) (DE-H1)
and the existing DE0 documents at
[`recipes/catalog/linux/SCHEMA.md`](../recipes/catalog/linux/SCHEMA.md).

This is a PoC-scoped architecture document. Production-breadth concerns
(geoclue / NetworkManager / PipeWire portal integration, evolution-data-server
calendar / contacts daemons, x-display-manager fallback path, GSettings DB
seeding, multi-monitor profile management, accessibility theming) are called
out as post-PoC follow-ups but not implemented in this milestone.

* DE-G2 — vm-harness Hyper-V GNOME boot test (consumes the rootfs layout
  decided here).
* DE-H1 — parallel Hyprland-equivalent doc (analogous shape; sway used as
  compositor stand-in for Hyprland).
* DE-K1 — KDE Plasma 6 doc (next phase).

## Summary of decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| GNOME version | **GNOME 42.x (jammy-native)** | Ubuntu 22.04 LTS shipped GNOME 42 as the desktop release. gdm3 42.0, gnome-shell 42.9, mutter 42.9, gnome-session 42.0, gnome-settings-daemon 42.1 are all in jammy main + universe with stable URLs on `archive.ubuntu.com`. Backporting GNOME 45+ would need newer GTK4 (4.10+), libadwaita (1.4+), gjs (1.76+), libmozjs (115+) and pulls a multi-week dependency cascade outside PoC scope. The DE-H1 lesson: pick the distro-native version, document the future-pin path. |
| Display manager | **gdm3 42.0** | Native autologin path via `/etc/gdm3/custom.conf` `[daemon] AutomaticLogin=repro`. Drops straight into a Wayland session; no greeter UI rendered for the headless PoC test. SDDM (DEM2 territory) is KDE's choice; LightDM is X11-leaning. |
| Compositor | **mutter --wayland** | GNOME's compositor; embedded inside `gnome-shell` for the desktop session. Same wlroots replacement story as DE-H1's sway: mutter ships its own clutter+cogl rendering stack rather than wlroots, but mounts the same Mesa + libdrm + libwayland + libxkbcommon foundation from DE0-G. |
| JS runtime | **gjs 1.72 + libmozjs-91** | `gnome-shell` is a JavaScript app; it embeds gjs which embeds SpiderMonkey 91 (`libmozjs-91-0.deb`, 4 MB). This is the single largest non-fontconfig dependency we ship; absolutely required. |
| Per-package store layout | `/opt/reproos-linux/store/<hash>/` (one subtree per catalog entry) | Matches DE0-G + DE-H1 exactly. No new store-layout decision. |
| Closure source | Ubuntu jammy main + universe `.deb`s | Same machinery as DE0-G + DE-H1. ~18.8 MB of new `.deb`s on top of the ~3.9 MB DE0-G + DE-H1 closure. Extracted footprint ~110 MB (mostly icon themes + gnome-shell assets + libmutter). |
| Auto-login user | **repro:1000** (provisioned by DE0-S) | gdm3 reads `/etc/gdm3/custom.conf`; the DE0-S session foundation already creates `repro:1000`. No new user-management work in DE-G1. |
| Session entry point | `/usr/local/bin/repro-start-gnome.sh` (shim) | Mirrors DE-H1's `repro-start-hyprland.sh`. Sources DE0-S session env, honours `REPRO_HEADLESS=1` (drives `MUTTER_DEBUG_DUMMY_MODE_SPECS=1024x768`), and execs `gnome-session`. |
| Wayland-session desktop file | `/etc/wayland-sessions/gnome.desktop` | Plants the desktop file under the standard GNOME name so gdm3 lists it. The `Exec=` line invokes `/usr/local/bin/repro-start-gnome.sh`. |
| Closure size budget | **~110 MB extracted** on top of DE0-G + DE-H1 | gnome-shell 3.9 MB + libmutter 4.5 MB + libgtk-4 14 MB + libmozjs 12 MB + libnss 4.5 MB + adwaita-icon-theme 13 MB + gnome-settings-daemon 1.3 MB + balance ~50 MB. Well under the spec's 600 MB DE-G1 budget. |
| Extension auto-load | **Disabled** | `disable-user-extensions=true` in default GSettings overrides; speeds first-boot. |
| Optional services | **`services.gnome.core-os-services` analog: OFF** | Skip evolution-data-server, geoclue2 daemon, gnome-online-accounts, gnome-remote-desktop. These need network + user-config UI; out of PoC scope. |
| PipeWire | **`libpipewire-0.3-0` only (shared lib for client)** | Ship the client shared library so gnome-shell + mutter resolve their `libpipewire-0.3.so.0` DT_NEEDED at load time. The PipeWire daemon (`pipewire`, `wireplumber`) is NOT planted; gnome-shell falls back gracefully when no daemon is reachable. Same stance DE-H1 took for `xdg-desktop-portal-wlr` w/o the portal daemon enabled. |

## Why GNOME 42 (not 45+)

The campaign-section prose said "GNOME 45+ on ReproOS". Empirical reality:

- `apt-cache show gnome-shell` on the harvest distro `repro-ubuntu` (jammy
  22.04.5 LTS): version **42.9-0ubuntu2.3**, available in jammy main.
- Backports of GNOME 45 / 46 / 47 to jammy: **none** in official Ubuntu
  archives. Backporters' PPAs exist but are not byte-stable and pull in
  newer GTK4, libadwaita, libmozjs, libnss; none of which jammy ships
  the right version of.
- A from-source build would need: meson 1.3+, glib 2.78+ (jammy ships
  2.72), libmozjs-115 (jammy ships -91), GTK 4.12+ (jammy ships 4.6),
  libadwaita 1.4+ (jammy ships 1.1). The chain has ~40+ explicit
  build-deps to backport individually.

DE-G1's gate is the architecture doc + catalog + builder + integration
test. **A from-source GNOME 45+ build is correctly scoped to a future
milestone "DE-G-build-gnome45-from-source" that does not block DE-G1.**

GNOME 42 is the correct PoC anchor because:

1. **Jammy-native.** Every catalog entry is one `apt-get download` away.
   ABI-compatible with DE0-G's Mesa 23.2.1 + DE-H1's libxkbcommon 1.4.0,
   libfontconfig 2.13, libcairo 1.16, libpango 1.50, libharfbuzz 2.7.
2. **Same Wayland foundation.** GNOME 42's mutter is the first release
   where the Wayland backend is non-experimental and default-on under
   gdm3. Architecturally identical to 45+ from the Wayland-IPC point of
   view (same `wl_display`, `wl_registry`, `xdg-shell`, `wlr-output-management`
   protocols).
3. **Smallest viable closure.** Newer GNOME pulls in libadwaita 1.4+
   (themed widget library), libgnome-bluetooth 42+, geoclue 2.7+ which
   would each drag transitive deps. GNOME 42's closure is ~25 catalog
   entries on top of DE0-G + DE-H1.
4. **Documented upgrade path.** When jammy → noble bump happens (post-PoC),
   the catalog entries flip version-pins; the build script + integration
   test are unchanged.

## NixOS reference architecture

NixOS reference modules consulted for the DE-G1 closure list and
service ordering:

- `nixos/modules/services/x11/desktop-managers/gnome.nix` — canonical
  GNOME enablement module. Pulls in `gnome-shell`, `mutter`, `gnome-session`,
  `gnome-settings-daemon`, `gnome-desktop`, GDM, the `xdg-desktop-portal-gnome`
  + `xdg-desktop-portal-gtk` portal backends, GTK 4 + libadwaita.
- `nixos/modules/services/x11/display-managers/gdm.nix` — GDM Wayland-mode
  service ordering. `Wants=systemd-user-sessions.service` +
  `WantedBy=graphical.target`. PAM stack `/etc/pam.d/gdm-launch-environment`
  for the gdm session worker.
- `nixos/modules/programs/dconf.nix` — dconf-service + dconf-gsettings-backend.
  Without this gnome-settings-daemon panics on startup.
- `nixos/modules/services/desktop-managers/none.nix` — minimal
  graphical-session.target setup the PoC mirrors.

The PoC does NOT re-implement nix or invoke nixpkgs at runtime; it reads
these modules for the canonical dependency closure, then re-implements
the equivalent as a `recipes/catalog/linux/` tier (parallel to DE0-G + DE-H1).

## Closure

Per-package planted artefacts for DE-G1 (on top of DE0-G + DE-H1 base):

| Catalog | Primary .deb(s) | Version | .deb size | Role |
|---------|-----------------|---------|-----------|------|
| `gdm.json` | `gdm3` + `libgdm1` | 42.0-1ubuntu7.22.04.4 | 376 KB | Display manager daemon. Ships gdm3 sbin + libgdm.so.1 + pam_gdm.so + 7 `/etc/pam.d/gdm-*` PAM stacks + `lib/systemd/system/gdm.service` + 1 dbus system.d conf. |
| `gnome-shell.json` | `gnome-shell` + `gnome-shell-common` | 42.9-0ubuntu2.3 | 1.06 MB | GNOME's JS-driven compositor session UI. Ships `/usr/bin/gnome-shell` + 5 libexec helpers + 8 desktop files + 11 dbus services. |
| `mutter.json` | `mutter` + `libmutter-10-0` + `mutter-common` | 42.9-0ubuntu9 | 1.50 MB | Wayland compositor + WM. Ships `/usr/bin/mutter` + libmutter-10.so.0 + 3 sub-libs (clutter / cogl / cogl-pango) + 1 plugin (`mutter-10/plugins/libdefault.so`). |
| `gnome-session.json` | `gnome-session-bin` + `gnome-session-common` | 42.0-1ubuntu2 | 135 KB | Session manager. Ships `/usr/bin/gnome-session` + 4 helpers + 6 libexec. The `gnome-session-common` deb ships `gnome-mimeapps.list`. |
| `gnome-settings-daemon.json` | `gnome-settings-daemon` + `gnome-settings-daemon-common` | 42.1-1ubuntu2.2 | 346 KB | 20 `gsd-*` libexec daemons (a11y, color, datetime, housekeeping, keyboard, media-keys, power, print, rfkill, screensaver, sharing, smartcard, sound, usb-protection, wacom + helper, wwan, xsettings, backlight, printer). |
| `libgnome-desktop.json` | `libgnome-desktop-3-19` + `gnome-desktop3-data` | 42.9-0ubuntu1 | 143 KB | GNOME desktop helper library. `libgnome-desktop-3.so.19` is hard-deped by gnome-shell + mutter + gnome-settings-daemon. The `-data` deb ships `/usr/share/gnome/`. |
| `libgjs.json` | `libgjs0g` | 1.72.4-0ubuntu0.22.04.4 | 402 KB | gjs (gnome-shell's JS engine) shared library. `gnome-shell` is a JS app; without this it fails to start. |
| `libmozjs91.json` | `libmozjs-91-0` | 91.10.0-0ubuntu1 | 4.07 MB | SpiderMonkey 91 — embedded by libgjs. Single largest dep in DE-G1; required for gnome-shell to interpret its JS. |
| `gjs.json` | `gjs` | 1.72.4-0ubuntu0.22.04.4 | 106 KB | gjs CLI (`/usr/bin/gjs-console`). Used by the integration test's smoke probe; gnome-shell only needs `libgjs.so.0` from `libgjs.json`. |
| `libgtk4.json` | `libgtk-4-1` + `libgtk-4-common` | 4.6.9+ds-0ubuntu0.22.04.2 | 3.53 MB | GTK 4 — libadwaita and xdg-desktop-portal-gtk depend on it. Largest single .deb in the DE-G1 closure. |
| `dconf.json` | `libdconf1` + `dconf-service` + `dconf-gsettings-backend` | 0.40.0-3ubuntu0.1 | 91 KB | dconf settings store. dconf-service is the daemon; dconf-gsettings-backend is the GIO module that gsettings transparently routes to dconf. **Cascade C hidden dep:** without dconf-gsettings-backend, `g_settings_new` returns the in-memory backend and gnome-settings-daemon panics. |
| `gsettings-desktop-schemas.json` | `gsettings-desktop-schemas` | 42.0-1ubuntu1 | 31 KB | GSettings schemas for desktop-level prefs (cursor, scaling, wallpaper, sound). All `gsd-*` daemons + mutter + gnome-shell load these at startup. |
| `libgraphene.json` | `libgraphene-1.0-0` | 1.10.8-1 | 48 KB | Math library for clutter (GPU vectors / matrices). libmutter-10.so.0 hard-links it. |
| `libgcr3.json` | `libgcr-base-3-1` + `libgck-1-0` | 3.40.0-4 | 290 KB | GCR (GNOME Crypto + p11-kit binding). gnome-shell links libgcr-base. |
| `libjson-glib.json` | `libjson-glib-1.0-0` | 1.6.6-1build1 | 70 KB | JSON parser for GLib. gnome-shell + mutter use it for the `clutter-conformance.json` test paths and the `runtime-config.json` reader. |
| `libsm.json` | `libsm6` | 2:1.2.3-1build2 | 17 KB | X11 Session Management library (legacy X11 session protocol). Cairo + gtk3 hard-link it via `libICE`. |
| `libice.json` | `libice6` | 2:1.0.10-1build2 | 43 KB | X11 Inter-Client Exchange library. `libSM` hard-deps it; gtk3 + gnome-shell load it via libcairo. |
| `libcanberra.json` | `libcanberra0` | 0.30-10ubuntu1.22.04.1 | 40 KB | Event sound library. gsd-sound uses it. The `libcanberra-alsa.so` plugin is shipped but the alsa-lib stack is NOT, so canberra falls back to the null backend at runtime — events are silent, but gsd-sound doesn't crash. |
| `libgudev.json` | `libgudev-1.0-0` | 1:237-2build1 | 16 KB | GObject wrapper around libudev. gnome-shell, mutter, libmutter, gsd-rfkill, gsd-power all hard-dep. |
| `libstartup-notification.json` | `libstartup-notification0` | 0.12-6build2 | 20 KB | X11 startup notification helper. libmutter + gnome-shell link it. |
| `libwacom.json` | `libwacom9` + `libwacom-common` | 2.2.0-1 | 76 KB | Wacom tablet device database. gsd-wacom + libmutter dep on it. The `-common` deb ships `/usr/share/libwacom/data/`. |
| `libxkbfile.json` | `libxkbfile1` | 1:1.1.0-1build3 | 72 KB | X11 xkb file loader (legacy). libmutter + gnome-shell link it for X11 keyboard layout fallback. |
| `accountsservice.json` | `accountsservice` + `libaccountsservice0` | 22.07.5-2ubuntu1.5 | 133 KB | accountsservice daemon + client library. gdm3 + gnome-shell read user lists through it. Ships `/usr/libexec/accounts-daemon` + system dbus service file. |
| `libsoup2.4.json` | `libsoup2.4-1` + `libsoup2.4-common` | 2.74.2-3ubuntu0.6 | 292 KB | HTTP library v2 (legacy API; v3 is what gnome-shell 45+ uses). gnome-shell 42 + xdg-desktop-portal-gtk hard-link libsoup-2.4. |
| `libsecret.json` | `libsecret-1-0` + `libsecret-common` | 0.20.5-2 | 128 KB | libsecret (secret-service client). gnome-shell + gnome-keyring link it. |
| `libpolkit.json` | `libpolkit-agent-1-0` + `libpolkit-gobject-1-0` | 0.105-33ubuntu0.1 | 60 KB | Polkit client libraries. gnome-shell + gsd-color + gsd-power all link to enforce auth on privileged operations. The polkit daemon itself is NOT shipped; gnome-shell falls back to "auth fails" for any escalation — acceptable for headless PoC. |
| `xdg-desktop-portal-gnome.json` | `xdg-desktop-portal-gnome` | 42.1-0ubuntu2 | 107 KB | GNOME backend for `xdg-desktop-portal`. Forwards file-chooser / screenshot / screencast requests to gnome-shell. |
| `xdg-desktop-portal-gtk.json` | `xdg-desktop-portal-gtk` | 1.14.0-1build1 | 87 KB | GTK backend for `xdg-desktop-portal`. The portal daemon (shipped by DE-H1's `xdg-desktop-portal.json`) routes screencast / openfile through this backend when on a GTK-based DE. |
| `adwaita-icon-theme.json` | `adwaita-icon-theme` | 41.0-1ubuntu1 | 3.44 MB | Default GNOME icon theme. Without this, mutter draws no cursor (falls back to ?-cursor) and gnome-shell's overview panel emits "icon not found" warnings for every app. |
| `libxkbcommon-x11.json` | `libxkbcommon-x11-0` | 1.4.0-1 | 14 KB | xkbcommon's X11 helper. libmutter + xkb-data interaction goes through it. DE0-G ships `libxkbcommon0`; this is the X11-specific add-on. |
| `libpipewire.json` | `libpipewire-0.3-0` | 0.3.48-1ubuntu3 | 274 KB | PipeWire client library. `xdg-desktop-portal` + gnome-shell DT_NEEDED at load time. The daemon (`pipewire`, `wireplumber`) is NOT planted; gnome-shell connects → ENOENT → falls back to "no screencast capability". |
| `libnss.json` | `libnss3` + `libnspr4` | 3.98 / 4.35 | 1.47 MB | Mozilla NSS (TLS + cert) + NSPR (portable runtime). gnome-shell hard-deps via libsoup2.4. |
| `libsystemd.json` | `libsystemd0` | 249.11-0ubuntu3.21 | 316 KB | systemd client library (`libsystemd.so.0`). gnome-shell + mutter + gnome-session + gnome-settings-daemon all hard-dep for sd_journal_send + sd_notify. **Cascade-class hidden dep:** the R9 from-source systemd install tree does ship a `libsystemd.so.0`, but jammy's gnome-shell was linked against the jammy build with different SONAME bytes; planting our own copy avoids ABI roulette. |

Total `.deb` closure added by DE-G1: **~18.8 MB compressed** (~110 MB
extracted). Combined DE0-G + DE-H1 + DE-G1 extracted footprint: ~135 MB.
Spec's "~600 MB" budget includes per-DE wallpaper assets we did NOT ship
(`ubuntu-wallpapers` 12 MB, `gnome-backgrounds` 200 MB+) — acceptable for
a headless PoC; user can drop their own image in `/usr/share/backgrounds/`.

## Layout schema

The single overlay tree DE-G1 produces (on top of DE0-G + DE-H1 base):

```
ReproOS rootfs (DE-G1 additions on top of DE0-S + DE0-D + DE0-G base)
======================================================================

  /opt/reproos-linux/store/                   Existing DE0-G + DE-H1 store;
                                              one subtree per catalog. DE-G1
                                              adds 33 new subtrees.
    <gdm-hash>/
      etc/pam.d/gdm-autologin
      etc/pam.d/gdm-fingerprint
      etc/pam.d/gdm-launch-environment
      etc/pam.d/gdm-password
      etc/pam.d/gdm-smartcard-pkcs11-exclusive
      etc/pam.d/gdm-smartcard-sssd-exclusive
      etc/pam.d/gdm-smartcard-sssd-or-password
      etc/dbus-1/system.d/gdm.conf
      lib/systemd/system/gdm.service
      lib/x86_64-linux-gnu/security/pam_gdm.so
      usr/bin/gdm-screenshot
      usr/bin/gdmflexiserver                  (from libgdm1.deb)
      usr/libexec/gdm-host-chooser
      usr/libexec/gdm-runtime-config
      usr/libexec/gdm-session-worker
      usr/libexec/gdm-simple-chooser
      usr/libexec/gdm-wayland-session
      usr/libexec/gdm-x-session
      usr/sbin/gdm3
      usr/lib/x86_64-linux-gnu/libgdm.so.1.0.0
      usr/lib/x86_64-linux-gnu/libgdm.so.1   (SONAME link)
    <gnome-shell-hash>/
      usr/bin/gnome-shell
      usr/bin/gnome-extensions
      usr/bin/gnome-shell-extension-tool
      usr/bin/gnome-shell-perf-tool
      usr/libexec/gnome-shell-calendar-server
      usr/libexec/gnome-shell-hotplug-sniffer
      usr/libexec/gnome-shell-perf-helper
      usr/libexec/gnome-shell-portal-helper
      usr/share/applications/org.gnome.Shell.desktop
      usr/share/dbus-1/services/org.gnome.Shell.*.service
    <mutter-hash>/
      usr/bin/mutter
      usr/libexec/mutter-restart-helper
      usr/lib/x86_64-linux-gnu/libmutter-10.so.0.0.0
      usr/lib/x86_64-linux-gnu/libmutter-10.so.0   (SONAME link)
      usr/lib/x86_64-linux-gnu/mutter-10/libmutter-clutter-10.so.0.0.0
      usr/lib/x86_64-linux-gnu/mutter-10/libmutter-cogl-10.so.0.0.0
      usr/lib/x86_64-linux-gnu/mutter-10/libmutter-cogl-pango-10.so.0.0.0
      usr/lib/x86_64-linux-gnu/mutter-10/plugins/libdefault.so
    ... (28 more subtrees follow the same shape) ...

    registry.json                             Existing DE0-G + DE-H1 registry;
                                              DE-G1 appends its 33 entries
                                              (sorted by name).

  /etc/ld.so.conf.d/00-reproos-linux.conf     Existing DE0-G + DE-H1 snippet;
                                              DE-G1 appends each new
                                              store-dir's lib path
                                              (including the mutter-10/
                                              sub-dir).

  /etc/gdm3/custom.conf                       NEW. AutomaticLoginEnable=true,
                                              AutomaticLogin=repro,
                                              WaylandEnable=true.

  /etc/wayland-sessions/gnome.desktop         NEW. Wayland session file
                                              gdm3 sees.
                                              Exec=/usr/local/bin/repro-start-gnome.sh.

  /usr/local/bin/repro-start-gnome.sh         NEW. Session entry shim;
                                              sources DE0-S session env,
                                              honours REPRO_HEADLESS,
                                              execs gnome-session.

  /etc/systemd/system/multi-user.target.wants/gdm.service
                                              NEW symlink → ../../../../
                                              opt/reproos-linux/store/<gdm-hash>/
                                              lib/systemd/system/gdm.service.
                                              Activates gdm at multi-user.target
                                              for the PoC (graphical.target
                                              is the production target).

  /etc/profile.d/gnome-gsettings.sh           NEW. Exports XDG_DATA_DIRS so
                                              gnome-shell finds the
                                              gsettings-desktop-schemas tree.

  /var/lib/reproos-de-gnome-done              NEW. Sentinel for idempotent
                                              re-apply (mirrors
                                              /var/lib/reproos-de-hyprland-done).
```

## DE-H1 cascade lessons inherited

These DE-H1 surprises landed as known pattern requirements; DE-G1's
builder implements them by reference, not by re-discovery:

1. **`/etc/profile.d/reproos-libpath.sh` planting (cascade E).**
   R9's from-source initramfs ships NO `ldconfig` and NO `ld.so.cache`
   builder. Without a cache, the dynamic linker IGNORES
   `/etc/ld.so.conf.d/*.conf` entries entirely. DE-H1 worked around this
   by exporting `LD_LIBRARY_PATH` from the same per-catalog libdirs that
   landed in `00-reproos-linux.conf`. DE-G1 appends its lib paths to the
   same env-export file (the DE-H1 builder already wrote one; DE-G1's
   builder UPDATES it after planting).

2. **`/etc/profile` splice for `/etc/profile.d/*.sh` sourcing (cascade E).**
   R9's `/etc/profile` is a 4-line static export and does NOT source
   `/etc/profile.d/*.sh` (BusyBox ash login shell follows the literal
   POSIX `/etc/profile` contract). DE-H1 spliced in a sourcing block;
   DE-G1 idempotently checks the marker and SKIPS if already spliced.

3. **`/usr/local/bin/<name>` symlink farm for autologin shell PATH
   (cascade B).** Binaries under `/opt/reproos-linux/store/<hash>/usr/bin/`
   need a `/usr/local/bin/<name>` symlink so the autologin shell finds
   them on PATH. DE-G1 plants symlinks for `gnome-shell`, `gnome-session`,
   `gnome-extensions`, `gjs-console`, `mutter`, `gdm-screenshot`,
   `gdmflexiserver`. The gdm3 sbin (`/usr/sbin/gdm3`) is symlinked into
   `/usr/local/sbin/`.

4. **Ldd audit BEFORE catalog finalization (cascade E).** DE-H1 surfaced
   the hidden xkb-data, fontconfig-config, libelf1, libxcb1, libglvnd,
   libwayland-cursor deps after the FIRST round of integration testing.
   DE-G1's catalog list was built from an empirical `ldd` audit of
   `/usr/bin/gnome-shell`, `/usr/bin/mutter`, `/usr/sbin/gdm3`, and
   `libmutter-10.so.0.0.0` AFTER extracting all candidate .debs into a
   shared tree. The "still-not-found" list after one pass was 13 libs;
   each is in the catalog above.

5. **Sentinel + idempotency.** `/var/lib/reproos-de-gnome-done` mirrors
   the DE-H1 sentinel; re-running the builder is a no-op until the
   sentinel is removed.

## `/etc/gdm3/custom.conf` shape

```
[daemon]
WaylandEnable=true
AutomaticLoginEnable=true
AutomaticLogin=repro
InitialSetupEnable=false

[security]

[xdmcp]

[chooser]

[debug]
```

Three knobs documented:

| Knob | Value | Effect |
|------|-------|--------|
| `WaylandEnable=true` | force Wayland | Disables the Xorg-fallback session path; mutter runs as the compositor. |
| `AutomaticLoginEnable=true` + `AutomaticLogin=repro` | autologin as repro | Skips the greeter UI entirely. DE0-S provisioned `repro:1000`. |
| `InitialSetupEnable=false` | skip first-run wizard | Without this, gnome-initial-setup runs once and blocks the session. Not in our closure anyway, but explicit kill-switch for robustness. |

## `/etc/wayland-sessions/gnome.desktop` shape

```
[Desktop Entry]
Name=GNOME
Comment=ReproOS GNOME Wayland session (DE-G1)
Exec=/usr/local/bin/repro-start-gnome.sh
TryExec=/usr/local/bin/gnome-shell
Type=Application
DesktopNames=GNOME
```

`TryExec=` lets gdm3 hide the session entry if the gnome-shell binary
isn't on PATH (defensive; the symlink-farm always plants it).

## Risks for DE-G2 (vm-harness boot test)

1. **Cascade G blocks the actual boot gate uniformly (same as DE-H2).**
   The R9 systemd dbus.socket non-activation issue surfaced by DE-H2 will
   surface DE-G2 too. DE-G1 lands cleanly because it's catalog + builder
   work; DE-G2 is the gate that's actually affected. Documented in the
   memo as "DE-H2 cascade G OPEN".

2. **No Hyper-V SyntheticVideo support in mutter's clutter backend.**
   mutter 42.9's clutter backend opens `/dev/dri/card0` via the DRM
   backend, same as sway in DE-H1. The DE0-K kernel enables
   `CONFIG_DRM_HYPERV=y` which creates `card0`; the DRM allocator path
   through `libgbm.so.1` lands on the llvmpipe software rasterizer.
   Backup: `MUTTER_DEBUG_DUMMY_MODE_SPECS=1024x768` (already wired into
   the start shim under `REPRO_HEADLESS=1`) skips the DRM backend
   entirely and renders to an off-screen surface. DE-G2 will need both.

3. **gnome-shell hard-deps `evolution-data-server` daemon.** The shell's
   calendar widget connects to EDS at `o.g.e.dataserver.AddressBook9`
   on startup. Without the daemon, the shell logs "EDS not available"
   warnings but continues. DE-G1 ships NO EDS daemon. The first-boot
   smoke gate must tolerate the warning. **Mitigated:** the integration
   test asserts the shell binary launches; it doesn't wait for the
   calendar to render.

4. **gnome-settings-daemon's `gsd-color` needs `libcolord.so.2`** which
   is NOT in DE-G1's closure (would pull libcolorhug + libgudev + DBus
   types + sqlite, 4 MB extra). gsd-color exits cleanly when libcolord
   is missing. DE-G2 will see gsd-color in journalctl as `Failed (no
   colord daemon)`; acceptable per PoC scope.

5. **gnome-shell's gjs JIT pages require `RX` memory mappings.** On
   Hyper-V with the default `vm.mmap_min_addr=65536` and no PaX/grsec,
   this should Just Work. DE-G1 ships no kernel param overrides; if
   DE-G2 surfaces a JIT-related crash, the fix is the same as DE-H1's
   `WLR_BACKENDS=headless` env-gate but for `JS_DISABLE_JIT=1` on the
   shim.

6. **dconf-service is a session-bus daemon.** gnome-settings-daemon
   connects to `ca.desrt.dconf.Writer`; without a running dconf-service,
   gsettings writes go to in-memory backend and the session crashes on
   second gsettings access. DE-G1 ships dconf-service but does NOT wire
   it into the user session's `default.target.wants/`. The shim's
   `repro-start-gnome.sh` invokes `dbus-daemon --session --fork` first;
   gnome-settings-daemon then activates dconf-service via DBus on demand.

7. **gdm3 needs `/var/lib/gdm3` writable as user `gdm:gdm`.** DE0-S
   provisioned `repro:1000` but NOT `gdm:gdm`. The DE-G1 build script
   creates `/var/lib/gdm3` with mode `0750` owned by gdm; DE-G2's boot
   gate must NOT reset this via systemd-tmpfiles. Documented as a
   /var/lib stateful exception.

8. **Symlink farm collision with DE-H1.** Both DE-H1 (sway) and DE-G1
   (gnome-shell) compete for `/usr/local/bin/foot`, `/usr/local/bin/waybar`,
   etc. DE-G1's only-binary symlinks are NAME-DISJOINT with DE-H1's
   (no overlap: `gnome-shell` vs `sway`, `gnome-session` vs nothing,
   `gdm-screenshot` vs nothing). When BOTH overlays compose into a
   multi-DE ISO (future DEM phase), no collision.

## Limitations (PoC scope)

- **No real graphical-session.target wiring.** DE-G1 plants gdm.service
  into `multi-user.target.wants/`, not `graphical.target.wants/`. The
  R9 base does not bring up graphical.target; multi-user is the
  highest target it reaches. DE-G2 may need to flip this if the boot
  test asserts graphical.target activation.
- **No transitive dep walker.** Same precedent as DE0-G + DE-H1: every
  catalog's `dependency_closure[]` is hand-curated and advisory.
- **No PipeWire daemon.** Only `libpipewire-0.3.so.0`. Screencast +
  audio over portal will fail; acceptable per PoC scope.
- **No evolution-data-server / geoclue / NetworkManager / colord
  daemons.** gnome-shell logs warnings and continues. No on-screen
  network indicator, no calendar feed, no location, no color mgmt.
- **No GPU acceleration.** llvmpipe software rasterization only.
  gnome-shell will be slow but functional under headless mode. Matches
  DE0-G's stance.
- **No theming customization.** Default Adwaita; no custom shell theme,
  no custom GTK theme, no wallpaper.
- **No multi-arch.** amd64-only. Same as DE-H1.
- **No signed envelopes.** Relies on `archive.ubuntu.com` over plain
  HTTP + sha256 pin. Matches DE-H1's stance.
- **No PAM stack customization beyond gdm-launch-environment.** The
  PAM stack is bit-for-bit jammy's; integration with the R9 minimal
  `/etc/pam.conf` is the responsibility of the build script's
  `gdm-launch-environment` planting.

## Future migration path

When DE-G-build-gnome45-from-source builds upstream GNOME 45+:

1. New catalog entry `recipes/catalog/linux/gnome-shell-built.json` with
   `provisioning_methods[].kind = "from-source"` (parallel to DE-H1's
   hyprland advisory).
2. The build script gains a conditional: if `gnome-shell-built.json` is
   present, plant it instead of the jammy gnome-shell 42 .deb.
3. `/etc/gdm3/custom.conf` is unchanged.
4. `/etc/wayland-sessions/gnome.desktop` is unchanged.
5. The compositor swap is **invisible to the rest of the rootfs** — no
   wayland-session.desktop change, no PAM change, no D-Bus change, no
   ld.so.conf.d change. Validates that the DE0 foundation is correctly
   isolated from the compositor identity.

Same architecture-invariance property DE-H1 established for the sway
→ Hyprland swap.

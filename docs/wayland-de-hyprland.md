# DE-H1: Hyprland on ReproOS (Wayland-DEs PoC — Phase DE-H)

**Status.** DE-H1 architecture decision — Phase DE-H of the
[`ReproOS-Wayland-DEs-PoC`](../../reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org)
campaign. Companion to [`multi-os-windows-runtime.md`](multi-os-windows-runtime.md) (W1),
[`multi-os-macos-runtime.md`](multi-os-macos-runtime.md) (D1), and the
existing DE0 documents at [`recipes/catalog/linux/SCHEMA.md`](../recipes/catalog/linux/SCHEMA.md).

This is a PoC-scoped architecture document. Production-breadth concerns
(per-DE GPU pass-through, full theming, user-mode auth, screen sharing
via xdg-desktop-portal pipeline integration) are called out as post-PoC
follow-ups but not implemented in this milestone.

* DE-H2 — vm-harness Hyper-V Hyprland boot test (consumes the rootfs
  layout decided here).
* DE-G1/DE-K1 — parallel GNOME / Plasma 6 docs (analogous shape; differ
  on display-manager + compositor + portal selection).

## Summary of decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Wayland compositor binary planted by DE-H1 | **Sway 1.7 (jammy-native)** as a Hyprland-architecturally-equivalent wlroots compositor | Hyprland has *no* pre-built jammy binary, *no* upstream binary release, and ships a 50 MB+ C++23 source tarball. Building from source needs hyprwayland-scanner + meson + 12 build deps; a multi-day cascade outside DE-H1 scope. Sway is jammy-native (`apt-cache show sway` returns 1.7-1, ~340 KB), wlroots-based (same DE0 dependency footprint as Hyprland would have), supplies an i3-compatible Wayland session, and validates the full DE0 foundation. Reserved: a future `hyprland-built-from-source` catalog entry replaces sway as the default compositor without changing the rest of the closure. |
| `hyprland.json` catalog entry | **Source-pinned advisory** (records upstream tarball sha256 + version but the build script does NOT plant it) | Carries the upstream `v0.41.2` source tarball pin for traceability. The `provisioning_methods[]` array marks it `kind: "upstream-source-tarball"`. The build script skips entries whose pin is `upstream-source-tarball` (build-from-source is out of DE-H1 scope; will land in a future "DE-H-build-hyprland" milestone). |
| Compositor closure source | Ubuntu jammy main + universe `.deb`s | Same machinery as DE0-G; no new fetcher. ~1.4 MB of new `.deb`s on top of the ~1.7 MB DE0-G base. |
| Per-package store layout | `/opt/reproos-linux/store/<hash>/` (one subtree per catalog entry) | Matches DE0-G exactly. No new store-layout decision. |
| Hyprland config file shape | `/etc/hyprland.conf` (planted even though the planted compositor is sway) + `/etc/sway/config` (the planted compositor's actual config) | The user-visible Hyprland config remains as the documented target shape; the active sway config translates each binding 1:1 (super+Return → foot, super+Q → kill, super+M → exit). When sway is swapped for upstream Hyprland in a future milestone, `/etc/hyprland.conf` is the only config the new compositor reads; `/etc/sway/config` becomes unused. |
| User session entry point | `/usr/local/bin/repro-start-hyprland.sh` (shim) | Sources DE0-S session env, exports `WLR_BACKENDS=headless` if `REPRO_HEADLESS=1`, and execs the planted compositor (`sway` today, `Hyprland` once it's planted). Single shim insulates the rest of the stack from the compositor swap. |
| Wayland-session desktop file | `/etc/wayland-sessions/hyprland.desktop` | Plants the desktop file under the documented Hyprland name so SDDM (DEM2) can list it. The `Exec=` line invokes `/usr/local/bin/repro-start-hyprland.sh` which dispatches to the planted compositor. |
| Closure size budget | **~1.5 MB additional** on top of DE0-G | Sway 340 KB + wlroots 290 KB + foot 240 KB + waybar 390 KB + xkb-data 394 KB + ~12 small support libs. Well under the spec's 50 MB DE-H1 budget; ~700 MB *total* closure goal includes Mesa + glibc + kernel which are already accounted for elsewhere. |

## Why sway (not Hyprland)

The DE-H1 campaign-section prose said:

> For PoC simplicity: **use the upstream Hyprland binary release tarball**
> (curl from GitHub Releases), sha256-pin, plant under `/opt/reproos-linux/store/<hash>/`.

Empirical reality at the time of this milestone:

- `apt-cache show hyprland` on the harvest distro `repro-ubuntu` (jammy
  22.04.5 LTS): **no packages found**. Jammy ships Hyprland nowhere.
- The Hyprland GitHub Releases (`v0.41.2`, `v0.55.4`, etc.) ship
  **source tarballs only** — `source-v0.41.2.tar.gz` (52 MB). There
  is no statically-linked `Hyprland.bin` asset to plant.
- A from-source build needs C++23 (`g++-13` minimum), `meson >= 1.3`,
  `hyprwayland-scanner` (itself a Hyprland-org C++ utility that must
  be built first), 12 wlroots + Wayland + xkbcommon + cairo + drm + udis86 +
  libliftoff dev deps, and a custom-patched wlroots fork (Hyprland 0.41 ships
  its own bundled wlroots tree). Building hyprwayland-scanner on jammy
  also needs C++23 — jammy's default g++-11 is C++20. The chain has
  ~30 explicit `apt install -y` packages on the build side.

DE-H1's gate is the architecture doc + catalog + builder + integration
test. **A from-source Hyprland build is correctly scoped to a future
milestone "DE-H-build-hyprland-from-source" that does not block DE-H1.**

`sway` is the correct PoC stand-in because:

1. **Same architectural family.** Both are wlroots-based Wayland
   compositors. Same DE0 prerequisites (Mesa + libdrm + libwayland +
   libxkbcommon + fontconfig). Anything we discover about session
   bringup, DRM device opening, seat acquisition via libseat, and
   compositor exit cleanup applies equally to Hyprland once it's
   built.
2. **Jammy-native.** `sway 1.7-1` in jammy universe is one
   `apt-get download` away. ABI-compatible with the DE0-G Mesa
   23.2.1 + libwayland 1.20.0 already planted.
3. **Smallest Wayland surface.** sway + swaybg + libwlroots10
   together are ~640 KB compressed. Hyprland's runtime closure is
   ~3 MB compressed (the binary alone is ~2 MB; the bundled wlroots
   adds ~1 MB). Sway is a tighter fit for the PoC's "smallest
   Wayland surface" goal than the original Hyprland target.
4. **Wayland-session compatibility.** sway plants
   `/usr/share/wayland-sessions/sway.desktop` natively. DE-H1 plants
   an additional `hyprland.desktop` pointing at the same compositor
   so a future SDDM (DEM2) sees the Hyprland session name even with
   sway as the implementation.

The `recipes/catalog/linux/hyprland.json` catalog entry **is** shipped,
but its `provisioning_methods[].kind = "upstream-source-tarball"` flags
it as an advisory pin the DE-H1 builder skips. A future
DE-H-build-hyprland milestone toggles this to `kind: "from-source"`
and adds the build recipe.

## NixOS reference architecture

NixOS reference modules consulted for the DE-H1 closure list and
service ordering:

- `nixos/modules/programs/wayland/hyprland.nix` — canonical Hyprland
  enablement module. Pulls in `hyprland`, `hyprlock`, `xdg-desktop-portal-hyprland`,
  enables `programs.xwayland`, plants the xdg-portal configuration.
- `nixos/modules/programs/wayland/sway.nix` — sway equivalent. Used as
  the PoC's actual configuration template since sway is what we plant.
  Pulls in `sway`, `swaybg`, `swayidle`, `swaylock`, `xdg-desktop-portal-wlr`.
- `nixos/modules/services/xserver/desktop-managers/none.nix` — minimal
  Wayland-only graphical-session.target setup the PoC mirrors.

The PoC does NOT re-implement nix or invoke nixpkgs at runtime; it reads
these modules for the canonical dependency closure, then re-implements
the equivalent as a `recipes/catalog/linux/` tier (parallel to DE0-G).

## Closure

Per-package planted artefacts for DE-H1 (on top of DE0-G base):

| Catalog | Primary .deb | Version | .deb size | Role |
|---------|--------------|---------|-----------|------|
| `sway.json` | `sway` | 1.7-1 | 341 KB | Wayland compositor (Hyprland stand-in). Ships `/usr/bin/sway`, `/usr/bin/swaybar`, `/usr/bin/swaymsg`, `/usr/bin/swaynag`, `/usr/share/wayland-sessions/sway.desktop`. |
| `sway.json` (cont.) | `swaybg` | 1.0-2build1 | 16 KB | Wallpaper helper (sway hard dep). |
| `wlroots.json` | `libwlroots10` | 0.15.1-2 | 290 KB | Modular Wayland compositor library. Hyprland 0.41 bundles its own fork; sway 1.7 dynamically links wlroots 0.15. |
| `foot.json` | `foot` | 1.11.0-2 | 240 KB | Lightweight Wayland terminal emulator (default DE terminal per spec). |
| `foot.json` (cont.) | `foot-terminfo` | 1.11.0-2 | 10 KB | `/usr/share/terminfo/f/foot` (required for `TERM=foot` to work). |
| `waybar.json` | `waybar` | 0.9.9-1 | 390 KB | Wayland status bar. Spec calls it out but it's optional at runtime; planted for SDDM/DEM2 readiness. |
| `xkb-data.json` | `xkb-data` | 2.33-1 | 394 KB | `/usr/share/X11/xkb/` keyboard layout database. libxkbcommon loads it at runtime; without it Hyprland/sway emit "no keymap" and freeze on input. **Hidden DE0-G dep surfaced by DE-H1.** |
| `fontconfig-config.json` | `fontconfig-config` | 2.13.1-4.2ubuntu5 | 29 KB | `/etc/fonts/fonts.conf` + 38 `conf.avail/*.conf` defaults. libfontconfig.so.1 reads this at runtime; without it `FcInit` returns no fonts. **Hidden DE0-G dep surfaced by DE-H1.** |
| `xdg-desktop-portal.json` | `xdg-desktop-portal` | 1.14.4-1ubuntu2~22.04.2 | 265 KB | Framework portal daemon. Forwards screenshot/screencast/openfile requests from Wayland clients to compositor-specific backends. |
| `xdg-desktop-portal-wlr.json` | `xdg-desktop-portal-wlr` | 0.5.0-3 | 34 KB | wlroots-family backend for the framework portal. Hyprland would use `xdg-desktop-portal-hyprland` (not in jammy); the wlr backend covers both sway and Hyprland for screenshot/screencast at the wlroots-protocol level. |
| `libelf1.json` | `libelf1` | 0.188-1~bpo22.04.1 | 188 KB | Mesa loads it at runtime for the GBM backend's ELF probing. **Hidden DE0-G dep surfaced by DE-H1.** |
| `libxcb1.json` | `libxcb1` | 1.14-3ubuntu3 | 49 KB | XCB base library — Mesa's xcb-egl path links it; wlroots' Xwayland integration links it. **Hidden DE0-G dep surfaced by DE-H1.** |
| `libxcb-extras.json` | 11 `libxcb-*` .debs | 1.14-3ubuntu3 | ~125 KB | dri2/dri3/present/randr/sync/xfixes/shm/composite/icccm/render/render-util/res/xinput. wlroots links them when probing X11 surfaces or driving XWayland; Mesa links a subset. Single catalog for the family to keep the JSON count down. |
| `libwayland-cursor.json` | `libwayland-cursor0` | 1.20.0-1ubuntu0.1 | 11 KB | Wayland cursor library (foot + sway link it). |
| `libseat.json` | `libseat1` | 0.6.4-1 | 28 KB | seatd-compatible seat-management ABI. wlroots uses it to acquire `/dev/dri/card0` + `/dev/input/*` without requiring systemd-logind for every path. |
| `libinput.json` | `libinput10` | 1.20.0-1ubuntu0.3 | 131 KB | Input event library wlroots dispatches keyboard/pointer through. |
| `libpixman.json` | `libpixman-1-0` | 0.40.0-1ubuntu0.22.04.1 | 264 KB | Pixel manipulation library Mesa's software path + sway link. |
| `libglvnd.json` | `libegl1` + `libgles2` | 1.4.0-1 | 47 KB | GL Vendor Neutral Dispatch. The DE0-G Mesa entry installs `libEGL_mesa.so.0`; libglvnd's `libEGL.so.1` is the dispatcher Wayland clients actually link. **Hidden DE0-G dep surfaced by DE-H1.** |
| `libxkbregistry.json` | `libxkbregistry0` | 1.4.0-1 | 14 KB | xkb-data registry library (waybar links it). |
| `libfcft.json` | `libfcft4` | 3.0.1-2 | 27 KB | font/character/freetype library (foot's font renderer). |
| `hyprland.json` | (advisory only) | `v0.41.2` upstream tarball | 52 MB | Source-pinned advisory entry. Build script SKIPS this catalog. Documents the upstream pin so a future DE-H-build-hyprland milestone has the sha256 ready. |

Total `.deb` closure added by DE-H1: **~2.4 MB compressed** (~9 MB
extracted). Well under the 50 MB budget. Combined DE0-G + DE-H1
extracted footprint: ~25 MB. Spec's "~700 MB total" includes kernel +
glibc + base rootfs which are accounted for in R8/R9, not DE-H1.

## Layout schema

The single overlay tree DE-H1 produces (on top of DE0-G's existing tree):

```
ReproOS rootfs (DE-H1 additions on top of DE0-S + DE0-D + DE0-G base)
======================================================================

  /opt/reproos-linux/store/                   Existing DE0-G store; one
                                              subtree per catalog. DE-H1
                                              adds 18 new subtrees.
    <sway-hash>/                              The compositor binaries.
      etc/sway/config                         Default sway config (the
                                              translation of /etc/hyprland.conf).
      usr/bin/sway
      usr/bin/swaybar
      usr/bin/swaymsg
      usr/bin/swaynag
      usr/share/wayland-sessions/sway.desktop
    <swaybg-hash>/
      usr/bin/swaybg
    <wlroots-hash>/
      usr/lib/x86_64-linux-gnu/libwlroots.so.10
    <foot-hash>/
      usr/bin/foot
      usr/bin/footclient
      usr/share/foot/foot.ini
      usr/share/terminfo/f/foot
      usr/share/terminfo/f/foot-direct
    <waybar-hash>/
      etc/xdg/waybar/config                   Default waybar config.
      etc/xdg/waybar/style.css                Default waybar style.
      usr/bin/waybar
    <xkb-data-hash>/
      usr/share/X11/xkb/...                   Keyboard layout data (~5000
                                              files, 5 MB extracted).
    <fontconfig-config-hash>/
      etc/fonts/fonts.conf                    System-wide fontconfig
      etc/fonts/conf.avail/                   conf snippets.
      etc/fonts/conf.d/README
    <xdg-desktop-portal-hash>/
      usr/libexec/xdg-desktop-portal          The portal daemon.
      usr/lib/systemd/user/xdg-desktop-portal.service
      usr/share/dbus-1/services/...           DBus activation files.
    <xdg-desktop-portal-wlr-hash>/
      usr/libexec/xdg-desktop-portal-wlr
      usr/lib/systemd/user/xdg-desktop-portal-wlr.service
      usr/share/xdg-desktop-portal/portals/wlr.portal
    <libelf1-hash>/
      usr/lib/x86_64-linux-gnu/libelf-0.188.so
      usr/lib/x86_64-linux-gnu/libelf.so.1   (SONAME link)
    <libxcb1-hash>/
      usr/lib/x86_64-linux-gnu/libxcb.so.1.1.0
      usr/lib/x86_64-linux-gnu/libxcb.so.1   (SONAME link)
    <libxcb-extras-hash>/
      usr/lib/x86_64-linux-gnu/libxcb-dri2.so.0.0.0
      usr/lib/x86_64-linux-gnu/libxcb-dri2.so.0   (SONAME link)
      usr/lib/x86_64-linux-gnu/libxcb-dri3.so.0.0.0
      usr/lib/x86_64-linux-gnu/libxcb-dri3.so.0
      ... (12 more pairs)
    <libwayland-cursor-hash>/
      usr/lib/x86_64-linux-gnu/libwayland-cursor.so.0.20.0
      usr/lib/x86_64-linux-gnu/libwayland-cursor.so.0
    <libseat-hash>/
      usr/lib/x86_64-linux-gnu/libseat.so.1
    <libinput-hash>/
      usr/lib/x86_64-linux-gnu/libinput.so.10.13.0
      usr/lib/x86_64-linux-gnu/libinput.so.10
    <libpixman-hash>/
      usr/lib/x86_64-linux-gnu/libpixman-1.so.0.40.0
      usr/lib/x86_64-linux-gnu/libpixman-1.so.0
    <libglvnd-hash>/
      usr/lib/x86_64-linux-gnu/libEGL.so.1.1.0
      usr/lib/x86_64-linux-gnu/libEGL.so.1
      usr/lib/x86_64-linux-gnu/libGLESv2.so.2.1.0
      usr/lib/x86_64-linux-gnu/libGLESv2.so.2
    <libxkbregistry-hash>/
      usr/lib/x86_64-linux-gnu/libxkbregistry.so.0.0.0
      usr/lib/x86_64-linux-gnu/libxkbregistry.so.0
    <libfcft-hash>/
      usr/lib/x86_64-linux-gnu/libfcft.so.4.0.1
      usr/lib/x86_64-linux-gnu/libfcft.so.4

    registry.json                             Existing DE0-G registry;
                                              DE-H1 appends its 18
                                              entries (sorted by name).

  /etc/ld.so.conf.d/00-reproos-linux.conf     Existing DE0-G snippet;
                                              DE-H1 appends each new
                                              store-dir's lib path.

  /etc/hyprland.conf                          NEW. Documented Hyprland
                                              config; future-proof for
                                              when the planted compositor
                                              becomes upstream Hyprland.
                                              Build script also writes
                                              /etc/sway/config translating
                                              every binding 1:1 so the
                                              planted sway has identical
                                              semantics.

  /etc/wayland-sessions/hyprland.desktop      NEW. Wayland session file
                                              SDDM/GDM/LightDM see.
                                              Exec=/usr/local/bin/repro-start-hyprland.sh.

  /usr/local/bin/repro-start-hyprland.sh      NEW. Session entry shim;
                                              sources DE0-S session env,
                                              honours REPRO_HEADLESS,
                                              execs the planted compositor.

  /var/lib/reproos-de-hyprland-done           NEW. Sentinel for idempotent
                                              re-apply (mirrors
                                              /var/lib/reproos-de0-graphics-done).
```

## Hyprland config translation table

The user-visible `/etc/hyprland.conf` is planted with the spec's minimal
config:

```
monitor=,preferred,auto,1
exec-once = waybar
bind = SUPER, Return, exec, foot
bind = SUPER, Q, killactive
bind = SUPER, M, exit
```

The planted compositor is sway; `/etc/sway/config` is its actual config.
The build script translates each Hyprland line 1:1:

| `/etc/hyprland.conf` | `/etc/sway/config` | Semantics |
|----------------------|--------------------|-----------|
| `monitor=,preferred,auto,1` | `output * mode preferred` | Single output, preferred mode. |
| `exec-once = waybar` | `exec waybar` | Spawn waybar at startup. |
| `bind = SUPER, Return, exec, foot` | `bindsym Mod4+Return exec foot` | Super+Enter spawns foot. |
| `bind = SUPER, Q, killactive` | `bindsym Mod4+q kill` | Super+Q kills focused window. |
| `bind = SUPER, M, exit` | `bindsym Mod4+m exit` | Super+M exits compositor. |

When upstream Hyprland is built in a future milestone, only the planted
compositor binary changes; `/etc/hyprland.conf` is already in place and
`/etc/sway/config` becomes vestigial (still present, ignored by Hyprland).

## Risks for DE-H2 (vm-harness boot test)

1. **No Hyper-V SyntheticVideo support in sway 1.7's wlroots 0.15.** Sway
   1.7 (wlroots 0.15) opens `/dev/dri/card0` directly via the DRM backend.
   The DE0-K kernel enables `CONFIG_DRM_HYPERV=y` which creates `card0`;
   the DRM allocator path through `libgbm.so.1` lands on the llvmpipe
   software rasterizer. Untested on Hyper-V SyntheticVideo specifically.
   Backup: `WLR_BACKENDS=headless` (already wired into the start shim)
   skips the DRM backend entirely and renders to an off-screen pixman
   surface. DE-H2 may need both code paths.
2. **xdg-desktop-portal pulls libpipewire-0.3-0 as a hard `Depends:`.**
   We're shipping the `xdg-desktop-portal_*.deb` binary but NOT installing
   its declared deps. At runtime the dynamic linker will fail to resolve
   `libpipewire-0.3.so.0` and the portal daemon will exit with status 127
   the moment it's socket-activated. The PoC compositor (sway) does NOT
   need the portal to run; the daemon is shipped for DEM-tier readiness
   only. The build script leaves the portal's systemd user units DISABLED
   by default (no `Wants=` from `graphical-session.target`); DE-H2 won't
   touch them. If the future DE-G1/DE-K1 milestone needs the portal at
   runtime, pipewire becomes a hard dep then.
3. **Sway needs `seatd.service` or systemd-logind running.** DE0-S
   selected systemd-logind. sway 1.7's libseat backend probes logind
   first (via `org.freedesktop.login1` on the system bus), then falls
   back to seatd. The DE0-S/DE0-D foundation provides logind + dbus;
   no new service required.
4. **Waybar needs a running compositor's `wl_display` to start.** Spec's
   `exec-once = waybar` is correct shape, but on a headless test (the
   `WLR_BACKENDS=headless` smoke path) waybar may print "failed to
   connect to display" and exit. The minimal Hyprland config commented
   below in `/etc/hyprland.conf` deliberately keeps `exec-once = waybar`
   for the user-facing case; the DE-H2 headless boot test asserts the
   compositor itself, not waybar.
5. **xkb-data path discovery.** libxkbcommon hard-codes the lookup
   prefix `/usr/share/X11/xkb/` at compile time (jammy's libxkbcommon
   1.4.0). We plant xkb-data under
   `/opt/reproos-linux/store/<hash>/usr/share/X11/xkb/` — NOT under
   `/usr/share/X11/xkb/`. The build script also writes a small
   `/etc/profile.d/xkb-data.sh` that exports `XKB_CONFIG_ROOT=/opt/reproos-linux/store/<hash>/usr/share/X11/xkb`
   so libxkbcommon's runtime override picks it up. **DE-H2 must source
   `/etc/profile` before invoking the compositor.**
6. **Mesa's EGL backend assumes `/usr/share/glvnd/egl_vendor.d/50_mesa.json`
   is at that path.** DE0-G plants it at
   `/opt/reproos-linux/store/<mesa-hash>/usr/share/glvnd/egl_vendor.d/50_mesa.json`.
   libglvnd's `libEGL.so.1` reads `__EGL_VENDOR_LIBRARY_DIRS` env var to
   locate vendor configs; build script writes a `/etc/profile.d/glvnd.sh`
   exporting it. Same prerequisite as #5 — **DE-H2 must source
   `/etc/profile` before invoking the compositor.**
7. **Hyper-V WaylandSession greeter UI.** None of GDM/SDDM/LightDM are
   in DE0/DE-H1 scope. DE-H2 boots straight to a TTY, autologins as
   `repro:1000`, and execs `/usr/local/bin/repro-start-hyprland.sh`.
   Greeter UI is DEM1/DEM2 work.

## Limitations (PoC scope)

- **No real Hyprland binary planted.** See "Why sway (not Hyprland)" above.
  The catalog reserves the slot; a future milestone fills it.
- **No transitive dep walker.** Same precedent as DE0-G: every catalog's
  `dependency_closure[]` is hand-curated and advisory. The build assumes
  the jammy host carries `libc6`, `libstdc++6`, `libcairo2`, `libgtk-3-0`,
  `libgdk-pixbuf-2.0-0`, `libudev1`, etc. (matches DE0-D's pattern).
- **xdg-desktop-portal-hyprland NOT planted.** Replaced by
  `xdg-desktop-portal-wlr` (wlroots-family generic). When upstream
  Hyprland lands, a separate catalog entry replaces the wlr backend.
- **No GPU acceleration.** llvmpipe software rasterization only. Matches
  DE0-G's stance.
- **No PipeWire stack.** xdg-desktop-portal-wlr's screencast path needs
  PipeWire; not shipped. Compositor + terminal + status bar all work
  without it.
- **No theming / cursor / wallpaper.** Sway boots to a black-or-grey
  background with the default cursor. swaybg is shipped but no wallpaper
  image is planted; user can add one via the standard config.
- **No multi-arch.** amd64-only. arm64 jammy debs would need parallel
  catalog entries with a `package.architecture` field (currently
  implicit via the `_amd64.deb` URL).
- **No signed envelopes.** Relies on `archive.ubuntu.com` over plain
  HTTP + sha256 pin. Matches DE0-G's stance.

## Future migration path

When DE-H-build-hyprland builds upstream Hyprland from source:

1. New catalog entry `recipes/catalog/linux/hyprland-built.json` with
   `provisioning_methods[].kind = "from-source"` and a build-recipe
   reference.
2. `recipes/reproos-mvp-config/build-mvp-hyprland-rootfs.sh` gains a
   conditional: if `hyprland-built.json` is present, plant Hyprland and
   skip sway; otherwise plant sway (the DE-H1 default).
3. `/etc/sway/config` becomes vestigial (left for back-compat / a future
   sway-also-shipped DE).
4. `/etc/hyprland.conf` is read by the new Hyprland binary unchanged.
5. The compositor swap is **invisible to the rest of the rootfs** — no
   wayland-session.desktop change, no PAM change, no D-Bus change, no
   ld.so.conf.d change. Validates that the DE0 foundation is correctly
   isolated from the compositor identity.

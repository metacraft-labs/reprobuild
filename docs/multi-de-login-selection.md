# DEM2: Single-image login-time DE selection on ReproOS

**Status.** DEM2 architecture decision -- Phase DEM of the
[`ReproOS-Wayland-DEs-PoC`](../../reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org)
campaign. Companion to:

- [`wayland-de-hyprland.md`](wayland-de-hyprland.md) (DE-H1)
- [`wayland-de-gnome.md`](wayland-de-gnome.md) (DE-G1)
- [`wayland-de-kde.md`](wayland-de-kde.md) (DE-K1)

DEM2 is the **stretch** milestone of the campaign: a single ReproOS image
that exposes all three Wayland desktop environments (Hyprland-equivalent,
GNOME 42, KDE Plasma 5.24) and lets the user pick the session at the
**login greeter UI**, rather than at GRUB boot-time (DEM1's selection
model).

This is a PoC-scoped document. Banner-green at runtime is not the gate;
the gate is the architecture + the integration-test infrastructure, with
the runtime banner attempts surfacing whatever the open cascades allow.

## Summary of decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Selection model | **Login-time (SDDM greeter UI)** | The PoC milestone spec defines DEM2 as the single-image alternative to DEM1's GRUB-cmdline `repro.de=<name>` model. The runtime hand-off is one extra step further into the boot than DEM1, so it surfaces strictly more of the cascade graph. |
| Greeter | **SDDM 0.19.0 (jammy)** | Empirical DE-K2 finding: SDDM **works** under cascade G in real boot (validated via Hyper-V boot of DE-K1 ISO during the DE-K2 sub-agent campaign). GDM was tested in DE-G2 + fell over: gdm.service's hard dependencies on accountsservice + the gdm user-bus + the gnome-session pre-stage hit multiple unmet preconditions in the R9 minimal systemd tree. The decision is "use what works": SDDM. |
| Session enumeration | **`/usr/share/wayland-sessions/*.desktop`** | freedesktop canonical path. SDDM scans this directory at greeter-start and lists one entry per `.desktop` file with a valid `[Desktop Entry]` block. The greeter UI surfaces the `Name=` line as the menu label and exec's the `Exec=` line when the user submits the form. |
| Sessions exposed | 3 (Hyprland / GNOME / Plasma Wayland) | One `.desktop` file per DE; each `Exec=` points at the per-DE `/usr/local/bin/repro-start-<de>.sh` shim the per-DE builder already plants. Total user-visible delta vs DEM1: no GRUB cmdline parsing, no `repro-de-select.service`. |
| Autologin | **Disabled** | DE-K1's stock `/etc/sddm.conf` carries an `[Autologin]` section that boots straight into Plasma Wayland without surfacing the greeter (this is what DE-K1's ISO ships, intentionally, to keep the Plasma path fast for vm-harness assertion). DEM2 strips `[Autologin]` -- otherwise the greeter never paints and the user cannot pick. |
| GRUB layout | **Single-entry (`REPRO_GRUB_VARIANT=single`)** | No per-DE GRUB menu (that is DEM1's domain). The DEM2 ISO ships ONE GRUB entry that boots straight to the SDDM greeter. |
| Wayland display server | **Forced via SDDM `[General] DisplayServer=wayland`** | The greeter itself runs as a Wayland client of a small compositor. We reuse `kwin_wayland` (already in the closure for DE-K1) as the greeter's compositor via `[Wayland] CompositorCommand=`. |
| HiDPI | **`EnableHiDPI=false`** | llvmpipe on a Hyper-V framebuffer has no meaningful DPI; Qt's auto-scaler picks up wrong values and renders the greeter at unusable sizes. Explicitly turn it off. |
| `display-manager.service` symlink | **Direct: -> `sddm.service`** | DEM1 leaves this symlink empty and lets `repro-de-select.service` write it at boot from the `repro.de=` cmdline. DEM2 wires it directly to SDDM at build-time (no boot-time helper needed). |
| GDM activation | **Pruned** | DE-G1 plants `multi-user.target.wants/gdm.service` unconditionally. If both gdm + sddm activate at multi-user.target, they race for the framebuffer; DEM2 removes the gdm activation so only SDDM runs. The gdm catalog tier itself remains in the closure (for libgdm consumers / future re-enable). |

## Pipeline

The DEM2 composer
[`recipes/reproos-mvp-config/build-mvp-multi-de-sddm-iso.sh`](../recipes/reproos-mvp-config/build-mvp-multi-de-sddm-iso.sh)
runs the same per-DE builders as DEM1 (DE-H1 + DE-G1 + DE-K1) against
the same overlay tree. The composition stages downstream of the per-DE
catalog plants differ:

| Stage | DEM1 | DEM2 |
|-------|------|------|
| 1-3 | Run DE-H1 + DE-G1 + DE-K1 builders. | Same. |
| 4   | Re-emit `/etc/profile.d/reproos-libpath.sh` from union LDCONF. | Same. |
| 5   | Mirror `/etc/wayland-sessions/*.desktop` -> `/usr/share/wayland-sessions/*`. | Same (this is the freedesktop canonical path SDDM enumerates). |
| 6   | Plant `/etc/systemd/system/repro-de-select.service` (oneshot) + `/usr/local/sbin/repro-de-select.sh` helper. | Rewrite `/etc/sddm.conf`: strip `[Autologin]`, add `[General] DisplayServer=wayland` + `[Wayland] EnableHiDPI=false`. |
| 7   | Remove gdm + sddm activations + `display-manager.service`; selector owns at boot. | Wire `display-manager.service` -> `sddm.service` directly (no selector). |
| 8   | n/a | Keep `multi-user.target.wants/sddm.service` (DE-K1 plants); remove `multi-user.target.wants/gdm.service`; defensively scrub any DEM1 artefacts (`repro-de-select.{service,sh}`). |

Net result: one SDDM unit started at multi-user.target, greeter paints,
lists 3 sessions, user picks, SDDM exec's the per-DE start shim.

## Integration with `build-mvp-iso.sh`

[`recipes/reproos-mvp-config/build-mvp-iso.sh`](../recipes/reproos-mvp-config/build-mvp-iso.sh)
stage 4k dispatches to either composer based on a new env var:

```
MVP_INCLUDE_MULTI_DE=1
MVP_DE_SELECTION_MODE={grub,login}   # default: grub  (= DEM1)
                                     # login    -> DEM2
```

The MULTI_DE gate is the same for both modes (same per-DE catalogs, same
binary symlink farm, same union LDCONF). The mode env var picks the
composer:

- `grub` -> `build-mvp-multi-de-iso.sh` (DEM1) + `REPRO_GRUB_VARIANT=multi-de`
- `login` -> `build-mvp-multi-de-sddm-iso.sh` (DEM2) + `REPRO_GRUB_VARIANT=single`

`grub` is the default for backwards compatibility with DEM1 callers.

## Rationale for SDDM vs GDM

The cascade-G debug graph (R9 systemd dbus.socket trip) was empirically
characterised during the DE-G2 + DE-K2 sub-agent campaigns:

- **GDM (DE-G2 finding)**. gdm.service hard-depends on accountsservice +
  the gdm user-bus + `gnome-session` autostart. The R9 minimal systemd
  install does not ship accountsservice; backporting it is a separate
  catalog tier we did not land in DE-G1. GDM's failure was "service
  starts, never paints greeter, eventually times out into a kernel
  panic". This was a banner failure for DE-G2.
- **SDDM (DE-K2 finding)**. sddm.service runs as a system unit + does
  its own greeter session-bus bring-up (sourced from `/etc/sddm.conf`
  `[Wayland] CompositorCommand=`). DE-K2 boot of the DE-K1 ISO under
  Hyper-V showed SDDM coming up cleanly, painting the greeter (autologin
  bypassed the painted greeter -- but the service-start telemetry
  matched the success criteria).

Conclusion: **use the working greeter**. For DEM2 we want the greeter UI
to surface, so we strip `[Autologin]` from DE-K1's `/etc/sddm.conf`. The
greeter then lists three sessions, and the user selects one.

## Session enumeration via `/usr/share/wayland-sessions/`

SDDM's session scanner walks two paths at greeter-start:

1. `/usr/share/wayland-sessions/` -- Wayland sessions (the freedesktop
   canonical location).
2. `/usr/share/xsessions/` -- X11 sessions (out of scope for the
   Wayland-only PoC).

Each `.desktop` file in (1) is parsed; SDDM requires a `[Desktop Entry]`
block with `Type=Application`, `Name=...`, and `Exec=...`. The DEM2
composer's stage 5 mirror lands three such files:

| File | Name= | Exec= |
|------|-------|-------|
| `hyprland.desktop` | Hyprland | `/usr/local/bin/repro-start-hyprland.sh` |
| `gnome.desktop` | GNOME | `/usr/local/bin/repro-start-gnome.sh` |
| `plasmawayland.desktop` | Plasma (Wayland) | `/usr/local/bin/repro-start-plasma.sh` |

Each `Exec=` shim sources the per-DE env (`/etc/profile.d/*.sh`),
honours `REPRO_HEADLESS=1` for the vm-harness assertion path, then
exec's the actual compositor / shell entrypoint.

## Risks of 3-way coexistence in a single rootfs

This is the section that doubles as a follow-up worklist. Within the PoC
scope we do not validate each of these end-to-end; we document them so
the post-PoC campaign can plan.

### Qt5 + GTK4 in the same closure

GNOME 42 ships GTK 4.6 + Adwaita. Plasma 5.24 ships Qt 5.15 + KF5 +
Breeze. Hyprland (substituted as sway in DE-H1) uses wlroots + Cairo +
Pango (so GTK-flavoured but not GTK-major-version-aware). All three
share the lower-half (libwayland-client, libxkbcommon, libdrm) through
the DE0-G catalog tier and do not conflict at that layer.

Above DE0-G, the Qt / GTK toolkits live in disjoint store dirs
(`/opt/reproos-linux/store/<qt5-base-hash>/...` and
`/opt/reproos-linux/store/<gtk4-hash>/...`); a single binary is linked
against exactly one of them (its catalog DT_NEEDED resolution). The
risks live in the search-path env vars that each toolkit reads at
startup:

- `QT_PLUGIN_PATH` (Qt 5 platform integration). DE-K1 plants
  `/etc/profile.d/plasma-qt.sh` which sets this from the Qt 5 catalog
  store dirs. Hyprland / GNOME do not link Qt 5 so they ignore this var;
  not a conflict.
- `XDG_DATA_DIRS` (icons, mime types, plasma themes). DE-K1 prepends
  every catalog's `usr/share/` to this list; DE-G1's gnome-session does
  the same. Order matters for theme resolution; the DEM2 composer's
  stage 4 union LDCONF re-emit is the canonical ordering (DE0-G first,
  then DE-H1, then DE-G1, then DE-K1).
- `XKB_CONFIG_ROOT`. Shared via DE0-G; no conflict.

### `/etc/profile.d/` composition

Each per-DE builder writes its own `/etc/profile.d/<de>-*.sh` fragment:

- `/etc/profile.d/reproos-libpath.sh` -- LD_LIBRARY_PATH (written by
  every per-DE builder last-writer-wins; the DEM2 composer's stage 4
  re-emits it once from the union LDCONF, canonical).
- `/etc/profile.d/plasma-qt.sh` -- QT_PLUGIN_PATH + QML2_IMPORT_PATH +
  XDG_DATA_DIRS extension (DE-K1 owns).
- `/etc/profile.d/gnome-env.sh` -- (DE-G1 owns; see DE-G1 builder for
  contents).

Order at shell init is alphabetical, so:
`gnome-env.sh` -> `plasma-qt.sh` -> `reproos-libpath.sh`. This means
LD_LIBRARY_PATH is set LAST, after Qt's plugin / QML paths and
GNOME's env. Each fragment's exports are additive (`KEY="newval${KEY:+:$KEY}"`)
so no conflict; values accumulate.

### Boot-time greeter race

If both gdm.service and sddm.service activate at multi-user.target, both
try to grab the framebuffer at the same time. systemd does not order
them; whichever wins the race paints, the other crashes on missing DRM
fd. The DEM2 composer's stage 8 removes the gdm activation symlink so
only SDDM is left.

### `/usr/share/wayland-sessions/` name collisions

Each DE plants its own session entry. The DEM1 + DEM2 path inherits the
DE-K1 catalog's `plasmawayland.desktop`, the DE-G1 catalog's
`gnome.desktop`, and the DE-H1 catalog's `hyprland.desktop`. Names are
disjoint -- no collision. The integration test asserts the absence of
`Name=` collisions across the three files (e.g. two files both with
`Name=GNOME` would surface as one entry in the SDDM UI).

### xdg-desktop-portal backend selection

`xdg-desktop-portal` is the freedesktop spec for cross-DE portal APIs
(screenshot, file picker, location, etc.). It dispatches to a backend
based on `XDG_CURRENT_DESKTOP`:

- `xdg-desktop-portal-kde` -- DE-K1 catalog tier.
- `xdg-desktop-portal-gnome` -- (would be in DE-G1; not currently
  planted -- if a portal call lands in a GNOME session it falls through
  to the default GTK portal).
- `xdg-desktop-portal-hyprland` -- (not currently planted; same
  fall-through).

This is a soft-functional gap that is invisible to the SDDM greeter +
the per-DE session start. Within PoC scope: accept the gap; document it
as a post-PoC item.

## Per-DE session start sequence (under SDDM)

When the user submits the greeter form, SDDM does roughly:

1. Forks. The child PAM-authenticates the user (the `sddm` PAM stack
   under `/etc/pam.d/sddm`).
2. Sets up `XDG_RUNTIME_DIR` (logind owns this; DE0-S unmasks logind).
3. Sources `/etc/profile.d/*.sh` (the union of all per-DE env fragments).
4. Exec's the `Exec=` line from the selected `.desktop` file. For DEM2,
   this is one of:
   - `/usr/local/bin/repro-start-hyprland.sh`
   - `/usr/local/bin/repro-start-gnome.sh`
   - `/usr/local/bin/repro-start-plasma.sh`
5. The shim exports DE-specific env (`XDG_CURRENT_DESKTOP=KDE` for
   Plasma; `XDG_CURRENT_DESKTOP=GNOME` for gnome-session; etc.) then
   exec's the compositor / session entrypoint.

## What this milestone does not validate at runtime

Per the campaign brief, DEM2 is the **stretch** milestone. The
acceptance is the architecture + the integration-test surface, NOT a
banner-green runtime gate. Specifically:

- **Greeter painting.** The SDDM greeter may or may not paint under
  cascade G + the linker cascade. We cover the start-of-service
  telemetry via `journalctl -u sddm`; the painted UI is best-effort.
- **3-DE session start.** Each of the three `repro-start-<de>.sh` shims
  has open per-DE cascades (DE-H2 / DE-G2 / DE-K2 partial outcomes).
  The DEM2 vm-harness test does not assert any of them lands
  banner-green; it asserts only that SDDM started + enumerated 3
  sessions.

The integration test
[`tests/integration/dem/t_dem2_login_selection.sh`](../tests/integration/dem/t_dem2_login_selection.sh)
gates the static composition; the vm-harness test
[`vm-harness/tests/e2e/t_vm_harness_hyperv_reproos_multi_de_sddm.nim`](../../vm-harness/tests/e2e/t_vm_harness_hyperv_reproos_multi_de_sddm.nim)
attempts a runtime probe + documents the cascade-G outcome.

## References

- [`recipes/reproos-mvp-config/build-mvp-multi-de-sddm-iso.sh`](../recipes/reproos-mvp-config/build-mvp-multi-de-sddm-iso.sh)
  -- the composer.
- [`recipes/reproos-mvp-config/build-mvp-iso.sh`](../recipes/reproos-mvp-config/build-mvp-iso.sh)
  -- stage 4k dispatcher (MVP_DE_SELECTION_MODE).
- [`tests/integration/dem/t_dem2_login_selection.sh`](../tests/integration/dem/t_dem2_login_selection.sh)
  -- DEM2 static composition gate.
- [`reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org`](../../reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org)
  DEM2 section -- campaign spec.

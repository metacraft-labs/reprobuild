#!/usr/bin/env bash
# build-mvp-multi-de-sddm-iso.sh -- DEM2 multi-DE rootfs composer
# (SDDM login-time selection variant of DEM1).
#
# Phase DEM, milestone DEM2 of the ReproOS-Wayland-DEs-PoC campaign:
# compose Hyprland (DE-H1) + GNOME 42 (DE-G1) + KDE Plasma 5.24 (DE-K1)
# into a SINGLE overlay rootfs, but instead of DEM1's GRUB-cmdline-driven
# selection (`repro.de=<name>` + repro-de-select.service flipping
# display-manager.service at boot) DEM2 plants a SINGLE display manager
# (SDDM) that exposes ALL THREE Wayland sessions to the user at the
# greeter UI via `/usr/share/wayland-sessions/*.desktop`.
#
# Decision rationale (DE-K2 finding):
#   - SDDM works under cascade G (validated in real boot during DE-K2).
#   - GDM does NOT work under cascade G (cascade G = R9 systemd
#     dbus.socket; GDM has a hard dependency on the system bus + its own
#     user-bus + accountsservice that has not survived the cascade).
#   - Conclusion: SDDM is the unified greeter. Plant `.desktop` session
#     files for ALL 3 DEs at the freedesktop canonical path
#     `/usr/share/wayland-sessions/`. User picks DE at the SDDM greeter.
#
# Composition (vs DEM1):
#
#   SAME as DEM1:
#     - Stage 1-3: run the three per-DE builders in order (DE-H1, DE-G1,
#       DE-K1) against the same overlay.
#     - Stage 4:   re-emit /etc/profile.d/reproos-libpath.sh from the
#                  union LDCONF (composition not last-writer-wins).
#     - Stage 5:   mirror /etc/wayland-sessions/*.desktop into
#                  /usr/share/wayland-sessions/* (freedesktop canonical).
#
#   DIFFERENT from DEM1:
#     - Stage 6 (NEW): rewrite /etc/sddm.conf to REMOVE [Autologin]
#                     section so the SDDM greeter UI surfaces; add
#                     [General] DisplayServer=wayland + [Wayland]
#                     EnableHiDPI=false.
#     - Stage 7 (NEW): symlink /etc/systemd/system/display-manager.service
#                     directly to the SDDM unit (no DEM1-style
#                     repro-de-select.service indirection).
#     - Stage 8 (NEW): keep the sddm.service multi-user.target.wants
#                     symlink the DE-K1 builder planted (DEM1 explicitly
#                     removed both gdm + sddm activation; DEM2 keeps
#                     sddm). Remove ONLY the gdm.service activation
#                     (avoid greeter race).
#     - Stage 9 (NEW): do NOT plant repro-de-select.service /
#                     repro-de-select.sh (no GRUB-level selection).
#
#   Net result: a single SDDM greeter listing 3 sessions:
#       Hyprland         -> /usr/local/bin/repro-start-hyprland.sh
#       GNOME            -> /usr/local/bin/repro-start-gnome.sh
#       Plasma (Wayland) -> /usr/local/bin/repro-start-plasma.sh
#
# Sentinel: $OVERLAY/var/lib/reproos-dem2-multi-de-sddm-done.
#
# Usage
# -----
#
#   build-mvp-multi-de-sddm-iso.sh
#     [--overlay-dir <path>]    # default: build/dem2-mvp/overlay
#     [--catalog-root <path>]   # default: recipes/catalog/linux/
#     [--vendored <path>]       # default: shared with DE0-G / DE-H1 / DE-G1 / DE-K1
#     [--allow-online]          # permit curl fetch when .deb missing
#     [--dry-run]
#     [--verbose]
#
# Exit codes:
#   0    success
#   1    argument / preflight error
#   2    per-DE builder invocation failed
#   3    overlay write failure

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CATALOG_ROOT="$REPO_ROOT/recipes/catalog/linux"
OVERLAY_DIR="${DEM2_OVERLAY_DIR:-$REPO_ROOT/build/dem2-mvp/overlay}"
VENDORED_DIR="${DEM2_VENDORED_DIR:-$SCRIPT_DIR/vendored-archives/linux}"
ALLOW_ONLINE=0
DRY_RUN=0
VERBOSE=0

# When dot-sourced from a parent driver (build-mvp-iso.sh stage 4k),
# honour the parent's vars.
[ -n "${MVP_OVERLAY_DIR:-}" ] && OVERLAY_DIR="$MVP_OVERLAY_DIR"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --overlay-dir)    OVERLAY_DIR="$2";    shift 2 ;;
    --overlay-dir=*)  OVERLAY_DIR="${1#--overlay-dir=}"; shift ;;
    --catalog-root)   CATALOG_ROOT="$2";   shift 2 ;;
    --catalog-root=*) CATALOG_ROOT="${1#--catalog-root=}"; shift ;;
    --vendored)       VENDORED_DIR="$2";   shift 2 ;;
    --vendored=*)     VENDORED_DIR="${1#--vendored=}"; shift ;;
    --allow-online)   ALLOW_ONLINE=1;      shift ;;
    --dry-run)        DRY_RUN=1;           shift ;;
    --verbose)        VERBOSE=1;           shift ;;
    -h|--help)
      sed -n '1,/^set -euo pipefail$/p' "$0" | sed -n '/^#/p' >&2
      exit 0 ;;
    *) echo "[dem2][error] unknown arg: $1" >&2; exit 1 ;;
  esac
done

log()  { echo "[dem2] $*" >&2; }
vlog() { [ "$VERBOSE" = 1 ] && echo "[dem2][verbose] $*" >&2 || true; }
die()  { echo "[dem2][error] $*" >&2; exit "${2:-1}"; }

[ -d "$CATALOG_ROOT" ] || die "catalog root missing: $CATALOG_ROOT" 1

# ---------------------------------------------------------------------------
# Preflight.
# ---------------------------------------------------------------------------

for t in python3 sha256sum stat dpkg-deb; do
  command -v "$t" >/dev/null 2>&1 || die "preflight: '$t' missing on PATH" 1
done
if [ "$ALLOW_ONLINE" = 1 ]; then
  command -v curl >/dev/null 2>&1 || die "preflight: 'curl' missing on PATH (required for --allow-online)" 1
fi

# ---------------------------------------------------------------------------
# Sentinel short-circuit.
# ---------------------------------------------------------------------------

SENTINEL="$OVERLAY_DIR/var/lib/reproos-dem2-multi-de-sddm-done"
if [ "$DRY_RUN" = 0 ] && [ -f "$SENTINEL" ]; then
  log "sentinel present ($SENTINEL); skipping (idempotent no-op)"
  exit 0
fi

if [ "$DRY_RUN" = 0 ]; then
  mkdir -p "$OVERLAY_DIR" "$VENDORED_DIR" \
           "$OVERLAY_DIR/etc/systemd/system" \
           "$OVERLAY_DIR/etc/systemd/system/multi-user.target.wants" \
           "$OVERLAY_DIR/etc/wayland-sessions" \
           "$OVERLAY_DIR/usr/share/wayland-sessions" \
           "$OVERLAY_DIR/var/lib"
fi

# ---------------------------------------------------------------------------
# Stage 1-3: compose the three per-DE builders.
# ---------------------------------------------------------------------------

run_builder() {
  local label="$1" script="$2"
  local sh="$SCRIPT_DIR/$script"
  [ -f "$sh" ] || die "$label builder missing: $sh" 2
  log "composing $label via $script"
  local args=( --overlay-dir "$OVERLAY_DIR" --vendored "$VENDORED_DIR" )
  [ "$ALLOW_ONLINE" = 1 ] && args+=( --allow-online )
  [ "$DRY_RUN" = 1 ] && args+=( --dry-run )
  [ "$VERBOSE" = 1 ] && args+=( --verbose )
  if [ "$label" != "DE-H1" ]; then
    args+=( --skip-de0-g )
  fi
  MVP_OVERLAY_DIR="$OVERLAY_DIR" \
    bash "$sh" "${args[@]}" 2>&1 | sed "s/^/[dem2]   /"
}

run_builder "DE-H1" "build-mvp-hyprland-rootfs.sh"
run_builder "DE-G1" "build-mvp-gnome-rootfs.sh"
run_builder "DE-K1" "build-mvp-plasma-rootfs.sh"

# ---------------------------------------------------------------------------
# Stage 4: re-emit /etc/profile.d/reproos-libpath.sh from the union
# LDCONF (composition not last-writer-wins; same pattern as DEM1).
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = 0 ]; then
  LDCONF="$OVERLAY_DIR/etc/ld.so.conf.d/00-reproos-linux.conf"
  [ -f "$LDCONF" ] || die "/etc/ld.so.conf.d/00-reproos-linux.conf missing after per-DE composition" 3

  log "re-emitting /etc/profile.d/reproos-libpath.sh from union LDCONF (composition, not last-write-wins)"
  LD_PATHS=""
  while IFS= read -r line; do
    case "$line" in
      ""|"#"*) continue ;;
      */qt5/qml) continue ;;
    esac
    if [ -z "$LD_PATHS" ]; then
      LD_PATHS="$line"
    else
      LD_PATHS="$LD_PATHS:$line"
    fi
  done < "$LDCONF"
  cat > "$OVERLAY_DIR/etc/profile.d/reproos-libpath.sh" <<EOF
# DEM2: composed LD_LIBRARY_PATH across DE-H1 + DE-G1 + DE-K1 + DE0-G.
#
# Authoritative union; same composition pattern as DEM1 (see DEM1
# composer for rationale). Order matches the union LDCONF (DE0-G first,
# then DE-H1, then DE-G1, then DE-K1).
export LD_LIBRARY_PATH="$LD_PATHS\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
EOF
fi

# ---------------------------------------------------------------------------
# Stage 5: mirror /etc/wayland-sessions/*.desktop into
# /usr/share/wayland-sessions/* (freedesktop canonical; SDDM enumerates
# this directory to populate the greeter session menu).
#
# Each .desktop file already carries an Exec= line pointing at the
# per-DE start shim:
#   hyprland.desktop      Exec=/usr/local/bin/repro-start-hyprland.sh
#   gnome.desktop         Exec=/usr/local/bin/repro-start-gnome.sh
#   plasmawayland.desktop Exec=/usr/local/bin/repro-start-plasma.sh
# DEM2 just propagates them to the canonical search path.
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = 0 ]; then
  log "mirroring /etc/wayland-sessions/*.desktop -> /usr/share/wayland-sessions/"
  for src in "$OVERLAY_DIR/etc/wayland-sessions/"*.desktop; do
    [ -f "$src" ] || continue
    base="$(basename "$src")"
    dst="$OVERLAY_DIR/usr/share/wayland-sessions/$base"
    cp -a "$src" "$dst"
    vlog "  mirrored $base"
  done

  for required in hyprland.desktop gnome.desktop plasmawayland.desktop; do
    [ -f "$OVERLAY_DIR/usr/share/wayland-sessions/$required" ] || \
      die "expected wayland-session file missing: $required" 3
  done
  log "/usr/share/wayland-sessions/ contains 3 session entries (hyprland, gnome, plasmawayland)"
fi

# ---------------------------------------------------------------------------
# Stage 6: rewrite /etc/sddm.conf for DEM2 (NO autologin; greeter UI
# surfaces; Wayland display server).
#
# DE-K1's builder planted an [Autologin] section pointing at the repro
# user + Session=plasmawayland.desktop -- that boots straight into
# Plasma and bypasses the greeter. DEM2's whole point is to surface
# the greeter so the user can pick. Strip [Autologin]; keep the [General]
# DisplayServer=wayland + the [Theme] Current=breeze branding.
#
# Preserve the [Wayland] CompositorCommand=kwin_wayland line because
# SDDM's Wayland greeter itself needs a compositor; reuse the DE-K1
# kwin_wayland binary (it's already in the closure).
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = 0 ]; then
  log "rewriting /etc/sddm.conf for DEM2 (no autologin; greeter UI)"

  # Best-effort extract the existing CompositorCommand= line from
  # DE-K1's /etc/sddm.conf so we keep the same store-pinned kwin_wayland
  # path. If the parse fails, fall back to the catalog-relative path
  # convention.
  EXISTING_SDDM_CONF="$OVERLAY_DIR/etc/sddm.conf"
  KWIN_COMPOSITOR_CMD=""
  if [ -f "$EXISTING_SDDM_CONF" ]; then
    KWIN_COMPOSITOR_CMD="$(grep -E '^CompositorCommand=' "$EXISTING_SDDM_CONF" | head -1 | cut -d= -f2- || true)"
  fi
  if [ -z "$KWIN_COMPOSITOR_CMD" ]; then
    # Fallback: find kwin_wayland in /usr/local/bin (the DE-K1 binary
    # symlink farm) and use that path.
    KWIN_COMPOSITOR_CMD="/usr/local/bin/kwin_wayland --no-lockscreen"
  fi
  vlog "  greeter compositor: $KWIN_COMPOSITOR_CMD"

  cat > "$OVERLAY_DIR/etc/sddm.conf" <<EOF
# DEM2: SDDM as the unified greeter for 3 Wayland sessions.
#
# No [Autologin] section: the greeter UI lists all .desktop files under
# /usr/share/wayland-sessions/ (hyprland, gnome, plasmawayland) and the
# user picks at the greeter.
#
# DisplayServer=wayland forces SDDM into Wayland-greeter mode. The
# greeter itself needs a compositor; we reuse kwin_wayland which DE-K1
# already plants. EnableHiDPI=false defeats Qt's auto-scaling on
# llvmpipe / VM framebuffers where the physical-pixel ratio is
# meaningless.

[General]
DisplayServer=wayland
Numlock=on

[Theme]
Current=breeze
CursorTheme=breeze_cursors

[Wayland]
EnableHiDPI=false
CompositorCommand=$KWIN_COMPOSITOR_CMD

[Users]
DefaultPath=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
EOF
fi

# ---------------------------------------------------------------------------
# Stage 7: point /etc/systemd/system/display-manager.service directly at
# SDDM (no DEM1-style repro-de-select.service indirection).
#
# DE-K1's builder planted display-manager.service -> sddm.service (under
# /opt/reproos-linux/store/<sddm-hash>/...). The per-DE composers
# (DE-G1's gdm symlink) and the DEM1 composer remove this; for DEM2 we
# want it BACK and pinned at SDDM specifically.
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = 0 ]; then
  log "wiring /etc/systemd/system/display-manager.service -> sddm.service"

  # Find sddm.service under /opt/reproos-linux/store/<sddm-hash>/lib/systemd/system/.
  SDDM_UNIT=""
  for cand in "$OVERLAY_DIR"/opt/reproos-linux/store/*/lib/systemd/system/sddm.service; do
    if [ -f "$cand" ]; then
      # Convert overlay-prefixed path to in-rootfs path.
      SDDM_UNIT="${cand#$OVERLAY_DIR}"
      break
    fi
  done

  if [ -z "$SDDM_UNIT" ]; then
    die "sddm.service unit not found under /opt/reproos-linux/store/; DE-K1 catalog missing?" 3
  fi
  vlog "  sddm unit: $SDDM_UNIT"

  # Force re-link (DE-K1 may have created this already pointing at the
  # right unit; the DEM1 composer if previously applied would have
  # removed it). ln -sf is idempotent.
  rm -f "$OVERLAY_DIR/etc/systemd/system/display-manager.service"
  ln -sf "$SDDM_UNIT" "$OVERLAY_DIR/etc/systemd/system/display-manager.service"
fi

# ---------------------------------------------------------------------------
# Stage 8: prune the gdm.service multi-user.target.wants activation (so
# only SDDM runs); keep sddm.service activation.
#
# DE-G1's builder planted gdm.service activation; DE-K1's builder
# planted sddm.service activation. DEM2 wants ONLY sddm active to avoid
# a greeter race on the framebuffer.
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = 0 ]; then
  GDM_ACT="$OVERLAY_DIR/etc/systemd/system/multi-user.target.wants/gdm.service"
  if [ -L "$GDM_ACT" ] || [ -e "$GDM_ACT" ]; then
    rm -f "$GDM_ACT"
    vlog "  removed multi-user.target.wants/gdm.service (DEM2: SDDM only)"
  fi

  # Defensive: assert sddm.service activation is present (DE-K1 planted
  # it).
  SDDM_ACT="$OVERLAY_DIR/etc/systemd/system/multi-user.target.wants/sddm.service"
  if [ ! -L "$SDDM_ACT" ] && [ ! -e "$SDDM_ACT" ]; then
    die "multi-user.target.wants/sddm.service activation symlink missing (DE-K1 should plant it)" 3
  fi
  vlog "  sddm.service activation present"

  # Ensure NO repro-de-select.service is wired (paranoia: if the DEM1
  # composer was run earlier against the same overlay, prune its
  # artefacts).
  for stale in repro-de-select.service; do
    stale_act="$OVERLAY_DIR/etc/systemd/system/multi-user.target.wants/$stale"
    if [ -L "$stale_act" ] || [ -e "$stale_act" ]; then
      rm -f "$stale_act"
      vlog "  removed stale DEM1 artefact: multi-user.target.wants/$stale"
    fi
    stale_unit="$OVERLAY_DIR/etc/systemd/system/$stale"
    if [ -f "$stale_unit" ]; then
      rm -f "$stale_unit"
      vlog "  removed stale DEM1 artefact: /etc/systemd/system/$stale"
    fi
  done
  stale_helper="$OVERLAY_DIR/usr/local/sbin/repro-de-select.sh"
  if [ -f "$stale_helper" ]; then
    rm -f "$stale_helper"
    vlog "  removed stale DEM1 artefact: /usr/local/sbin/repro-de-select.sh"
  fi

  # Pin mtimes.
  find "$OVERLAY_DIR/etc/systemd/system" \
       "$OVERLAY_DIR/etc/profile.d/reproos-libpath.sh" \
       "$OVERLAY_DIR/etc/sddm.conf" \
       "$OVERLAY_DIR/usr/share/wayland-sessions" \
       -exec touch -h --date="@$SOURCE_DATE_EPOCH" {} + 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Stage 9: sentinel + summary.
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = 0 ]; then
  cat > "$SENTINEL" <<EOF
DEM2 multi-DE composition applied (SDDM unified greeter).
Date: $(date -u +%Y-%m-%dT%H:%M:%SZ -d "@$SOURCE_DATE_EPOCH")
Overlay: $OVERLAY_DIR
Source: ubuntu-jammy (.deb harvest)

Composed DEs:
  - DE-H1 (Hyprland-equivalent, sway-as-Hyprland)
  - DE-G1 (GNOME 42)
  - DE-K1 (KDE Plasma 5.24)
Selection model: login-time via SDDM greeter (cf. DEM1: boot-time via GRUB)

Decision (DE-K2 finding): SDDM works under cascade G, GDM does not.
SDDM is the unified greeter.

Per-DE sentinels:
  /var/lib/reproos-de-hyprland-done
  /var/lib/reproos-de-gnome-done
  /var/lib/reproos-de-plasma-done

DEM2 planted:
  /etc/sddm.conf                                              (no autologin; Wayland greeter)
  /etc/systemd/system/display-manager.service -> sddm.service (direct, no selector)
  /etc/profile.d/reproos-libpath.sh                           (union LD_LIBRARY_PATH; composed)
  /usr/share/wayland-sessions/hyprland.desktop                (freedesktop canonical)
  /usr/share/wayland-sessions/gnome.desktop                   (freedesktop canonical)
  /usr/share/wayland-sessions/plasmawayland.desktop           (freedesktop canonical)

Kept (DE-K1 owns):
  /etc/systemd/system/multi-user.target.wants/sddm.service    (SDDM activation)

Removed (DEM2 prunes):
  /etc/systemd/system/multi-user.target.wants/gdm.service     (avoid greeter race)
  /etc/systemd/system/repro-de-select.service                 (DEM1 artefact; not used)
  /etc/systemd/system/multi-user.target.wants/repro-de-select.service
  /usr/local/sbin/repro-de-select.sh                          (DEM1 artefact; not used)

Login-time DE selection:
  User boots into SDDM greeter, picks session from drop-down:
    Hyprland               -> /usr/local/bin/repro-start-hyprland.sh
    GNOME                  -> /usr/local/bin/repro-start-gnome.sh
    Plasma (Wayland)       -> /usr/local/bin/repro-start-plasma.sh

Next step:
  Pair with build-mvp-iso.sh stage 4k (MVP_INCLUDE_MULTI_DE=1
  MVP_DE_SELECTION_MODE=login) + recipes/reproos-iso/scripts/build-iso.sh
  (single-entry GRUB; no per-DE menu) to assemble the multi-DE ISO.
EOF

  touch -h --date="@$SOURCE_DATE_EPOCH" "$SENTINEL" 2>/dev/null || true
fi

log "DEM2 multi-DE composition DONE (mode=login dry_run=$DRY_RUN)"
exit 0

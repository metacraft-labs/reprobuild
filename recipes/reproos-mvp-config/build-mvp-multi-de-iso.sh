#!/usr/bin/env bash
# build-mvp-multi-de-iso.sh -- DEM1 multi-DE rootfs composer.
#
# Phase DEM, milestone DEM1 of the ReproOS-Wayland-DEs-PoC campaign:
# compose Hyprland (DE-H1) + GNOME 42 (DE-G1) + KDE Plasma 5.24 (DE-K1)
# into a SINGLE overlay rootfs, plant a GRUB-cmdline-driven DE selector,
# and surface a /usr/share/wayland-sessions tree containing all three
# session .desktop files for DEM2.
#
# Pipeline:
#
#   1. Call build-mvp-hyprland-rootfs.sh against $OVERLAY (default DE).
#   2. Call build-mvp-gnome-rootfs.sh    against $OVERLAY.
#   3. Call build-mvp-plasma-rootfs.sh   against $OVERLAY.
#      Each builder is idempotent + writes its own sentinel; running all
#      three against the same $OVERLAY composes the three catalog tiers
#      without conflicts (binary-symlink farms are name-disjoint).
#
#   4. RECOMPOSE /etc/profile.d/reproos-libpath.sh from the FINAL
#      LDCONF state so the user shell + every per-DE start shim get
#      LD_LIBRARY_PATH covering all three DEs. The individual builders
#      already over-write this file last-writer-wins; this pass is the
#      authoritative re-emit from the union LDCONF.
#
#      Per the DEM1 brief (DE-G2 risk #2): the multi-DE driver MUST
#      compose /etc/profile.d/*-libpath.sh fragments rather than replace.
#      We achieve composition by reading from the union LDCONF which
#      already accumulates entries from all three DE catalog passes
#      (each builder APPENDS to LDCONF; only the env-export file got
#      rewritten last-writer-wins).
#
#   5. Mirror /etc/wayland-sessions/*.desktop to
#      /usr/share/wayland-sessions/*.desktop (DEM2 readiness; the
#      freedesktop spec puts session entries under /usr/share, while
#      the existing builders put them under /etc/ for SDDM/GDM
#      compatibility). Mirrored via symlink for byte-stability.
#
#   6. Plant /etc/systemd/system/repro-de-select.service (oneshot before
#      display-manager.service / graphical.target) + the ExecStart helper
#      /usr/local/sbin/repro-de-select.sh. The helper reads /proc/cmdline,
#      parses `repro.de=<name>`, and SYMLINKS
#      /etc/systemd/system/display-manager.service to the chosen DE's
#      service unit:
#
#        repro.de=hyprland  -> no display-manager (autologin getty)
#        repro.de=gnome     -> gdm.service
#        repro.de=plasma    -> sddm.service
#
#      Default (no cmdline gate or invalid value): hyprland.
#
#   7. Override the multi-user.target.wants display-manager wiring that
#      DE-G1 + DE-K1 planted unconditionally. The repro-de-select.service
#      lives at multi-user.target.wants priority and re-arranges the
#      symlink farm at boot. Without this override, gdm + sddm would
#      both race to grab the framebuffer.
#
#      We REMOVE the gdm/sddm multi-user.target.wants symlinks the
#      individual builders planted and let repro-de-select.service own
#      that decision at boot time.
#
#   8. Plant the DEM1 sentinel /var/lib/reproos-dem1-multi-de-done with
#      a summary of which DEs were composed.
#
# Sentinel: $OVERLAY/var/lib/reproos-dem1-multi-de-done.
#
# Composition with DE0-G / DE-H1 / DE-G1 / DE-K1.
#
#   This script does NOT do its own catalog work; it composes the three
#   existing builders. Each builder calls build-linux-graphics-stack.sh
#   (DE0-G) if its sentinel is missing, then plants its catalog tier +
#   compositor-config layer; later builders short-circuit on the DE0-G
#   sentinel. The DE-H1 layer goes down first (default DE), then DE-G1
#   (gdm + gnome-shell), then DE-K1 (sddm + plasma).
#
# Usage
# -----
#
#   build-mvp-multi-de-iso.sh
#     [--overlay-dir <path>]    # default: build/dem1-mvp/overlay
#     [--catalog-root <path>]   # default: recipes/catalog/linux/
#     [--vendored <path>]       # default: shared with DE0-G / DE-H1 / DE-G1 / DE-K1
#     [--allow-online]          # permit curl fetch when .deb missing
#     [--default-de <name>]     # default: hyprland (smallest, fastest validation)
#     [--dry-run]
#     [--verbose]
#
# Exit codes:
#   0    success
#   1    argument / preflight error
#   2    per-DE builder invocation failed
#   3    overlay write failure
#   4    invalid --default-de value

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CATALOG_ROOT="$REPO_ROOT/recipes/catalog/linux"
OVERLAY_DIR="${DEM1_OVERLAY_DIR:-$REPO_ROOT/build/dem1-mvp/overlay}"
VENDORED_DIR="${DEM1_VENDORED_DIR:-$SCRIPT_DIR/vendored-archives/linux}"
ALLOW_ONLINE=0
DEFAULT_DE="hyprland"
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
    --default-de)     DEFAULT_DE="$2";     shift 2 ;;
    --default-de=*)   DEFAULT_DE="${1#--default-de=}"; shift ;;
    --dry-run)        DRY_RUN=1;           shift ;;
    --verbose)        VERBOSE=1;           shift ;;
    -h|--help)
      sed -n '1,/^set -euo pipefail$/p' "$0" | sed -n '/^#/p' >&2
      exit 0 ;;
    *) echo "[dem1][error] unknown arg: $1" >&2; exit 1 ;;
  esac
done

log()  { echo "[dem1] $*" >&2; }
vlog() { [ "$VERBOSE" = 1 ] && echo "[dem1][verbose] $*" >&2 || true; }
die()  { echo "[dem1][error] $*" >&2; exit "${2:-1}"; }

case "$DEFAULT_DE" in
  hyprland|gnome|plasma) ;;
  *) die "invalid --default-de '$DEFAULT_DE' (must be hyprland|gnome|plasma)" 4 ;;
esac

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

SENTINEL="$OVERLAY_DIR/var/lib/reproos-dem1-multi-de-done"
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
           "$OVERLAY_DIR/usr/local/sbin" \
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
  # The first builder (DE-H1) brings in DE0-G; subsequent builders skip
  # the DE0-G compose via --skip-de0-g (idempotent either way, but
  # --skip-de0-g avoids a redundant sentinel-check + log noise).
  if [ "$label" != "DE-H1" ]; then
    args+=( --skip-de0-g )
  fi
  MVP_OVERLAY_DIR="$OVERLAY_DIR" \
    bash "$sh" "${args[@]}" 2>&1 | sed "s/^/[dem1]   /"
}

run_builder "DE-H1" "build-mvp-hyprland-rootfs.sh"
run_builder "DE-G1" "build-mvp-gnome-rootfs.sh"
run_builder "DE-K1" "build-mvp-plasma-rootfs.sh"

# ---------------------------------------------------------------------------
# Stage 4: re-emit /etc/profile.d/reproos-libpath.sh from the union
# LDCONF.
#
# Per the DE-G2 report risk #2 the splice MUST compose rather than be
# last-writer-wins. The individual builders already APPEND to LDCONF
# (so LDCONF accumulates correctly); only the env-export shim got
# overwritten by each builder's tail. We rewrite it once here from the
# authoritative union.
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
# DEM1: composed LD_LIBRARY_PATH across DE-H1 + DE-G1 + DE-K1 + DE0-G.
#
# This file is the AUTHORITATIVE union of every catalog tier's library
# directories. The individual per-DE builders (build-mvp-hyprland-rootfs.sh,
# build-mvp-gnome-rootfs.sh, build-mvp-plasma-rootfs.sh) each write their
# own variant of this file last-writer-wins; the DEM1 composer re-emits
# it once from the UNION /etc/ld.so.conf.d/00-reproos-linux.conf so the
# autologin user shell + each per-DE start shim see the FULL list.
#
# Per the DEM1 brief / DE-G2 risk #2 ("compose fragments rather than
# replace"): this is the composition pattern. Order matches the union
# LDCONF (DE0-G first, then DE-H1, then DE-G1, then DE-K1).
export LD_LIBRARY_PATH="$LD_PATHS\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
EOF
fi

# ---------------------------------------------------------------------------
# Stage 5: mirror /etc/wayland-sessions/*.desktop into
# /usr/share/wayland-sessions/*.desktop (DEM2 readiness; freedesktop
# canonical path).
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

  # Defensive check: every expected session file must be present. No
  # name collisions: hyprland.desktop / gnome.desktop / plasmawayland.desktop.
  for required in hyprland.desktop gnome.desktop plasmawayland.desktop; do
    [ -f "$OVERLAY_DIR/usr/share/wayland-sessions/$required" ] || \
      die "expected wayland-session file missing: $required" 3
  done
  log "/usr/share/wayland-sessions/ contains 3 session entries (hyprland, gnome, plasmawayland)"
fi

# ---------------------------------------------------------------------------
# Stage 6: plant the DE-selector systemd oneshot + helper.
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = 0 ]; then
  log "planting /usr/local/sbin/repro-de-select.sh"
  cat > "$OVERLAY_DIR/usr/local/sbin/repro-de-select.sh" <<EOF
#!/usr/bin/env bash
# DEM1: boot-time desktop-environment selector.
#
# Reads /proc/cmdline for repro.de=<name> and arranges the
# /etc/systemd/system/display-manager.service symlink to point at the
# chosen DE's display-manager unit. Default DE: $DEFAULT_DE.
#
# Recognised values:
#
#   repro.de=hyprland  -> no display-manager.service (autologin getty)
#   repro.de=gnome     -> gdm.service
#   repro.de=plasma    -> sddm.service
#
# Invalid / missing values default to $DEFAULT_DE.

set -e

# Parse /proc/cmdline for repro.de=<name>. Word-tokenize on whitespace
# so escaped values do not corrupt parsing.
chosen=""
if [ -r /proc/cmdline ]; then
  for word in \$(cat /proc/cmdline); do
    case "\$word" in
      repro.de=*) chosen="\${word#repro.de=}" ;;
    esac
  done
fi

case "\$chosen" in
  hyprland|gnome|plasma) ;;
  *) chosen="$DEFAULT_DE" ;;
esac

DM_LINK="/etc/systemd/system/display-manager.service"

# Resolve target. The gdm + sddm unit-paths are catalog-hash-relative;
# we re-derive at boot from the catalog-symlink farm under
# /opt/reproos-linux/store/*/lib/systemd/system/.
find_unit() {
  local unit="\$1" hit=""
  for cand in /opt/reproos-linux/store/*/lib/systemd/system/"\$unit"; do
    [ -f "\$cand" ] || continue
    hit="\$cand"
    break
  done
  echo "\$hit"
}

case "\$chosen" in
  hyprland)
    # Remove any existing display-manager symlink so neither gdm nor
    # sddm contends with the autologin getty.
    rm -f "\$DM_LINK"
    echo "[repro-de-select] hyprland: no display-manager (autologin getty path)" >&2
    ;;
  gnome)
    target="\$(find_unit gdm.service)"
    if [ -n "\$target" ]; then
      ln -sf "\$target" "\$DM_LINK"
      echo "[repro-de-select] gnome: display-manager.service -> \$target" >&2
    else
      echo "[repro-de-select] WARN: gdm.service unit not found under /opt/reproos-linux/store/" >&2
    fi
    ;;
  plasma)
    target="\$(find_unit sddm.service)"
    if [ -n "\$target" ]; then
      ln -sf "\$target" "\$DM_LINK"
      echo "[repro-de-select] plasma: display-manager.service -> \$target" >&2
    else
      echo "[repro-de-select] WARN: sddm.service unit not found under /opt/reproos-linux/store/" >&2
    fi
    ;;
esac

exit 0
EOF
  chmod +x "$OVERLAY_DIR/usr/local/sbin/repro-de-select.sh"

  log "planting /etc/systemd/system/repro-de-select.service"
  cat > "$OVERLAY_DIR/etc/systemd/system/repro-de-select.service" <<'EOF'
[Unit]
Description=ReproOS DEM1 desktop-environment selector
DefaultDependencies=no
After=local-fs.target
Before=display-manager.service graphical.target
ConditionPathExists=/usr/local/sbin/repro-de-select.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/repro-de-select.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  # Wire the oneshot into multi-user.target.wants so systemd runs it
  # before the (subsequent) display-manager.service start.
  ln -sf "/etc/systemd/system/repro-de-select.service" \
         "$OVERLAY_DIR/etc/systemd/system/multi-user.target.wants/repro-de-select.service"
fi

# ---------------------------------------------------------------------------
# Stage 7: remove the gdm + sddm multi-user.target.wants symlinks the
# per-DE builders planted unconditionally. The repro-de-select.service
# now owns the display-manager.service choice at boot time.
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = 0 ]; then
  for stale in gdm.service sddm.service; do
    stale_link="$OVERLAY_DIR/etc/systemd/system/multi-user.target.wants/$stale"
    if [ -L "$stale_link" ] || [ -e "$stale_link" ]; then
      rm -f "$stale_link"
      vlog "  removed legacy multi-user.target.wants link: $stale"
    fi
  done

  # Also remove the /etc/systemd/system/display-manager.service that
  # DE-K1 planted unconditionally. repro-de-select.service writes this
  # at boot per repro.de=.
  stale_dm="$OVERLAY_DIR/etc/systemd/system/display-manager.service"
  if [ -L "$stale_dm" ] || [ -e "$stale_dm" ]; then
    rm -f "$stale_dm"
    vlog "  removed legacy display-manager.service link (will be set at boot)"
  fi

  # Pin mtimes.
  find "$OVERLAY_DIR/etc/systemd/system" \
       "$OVERLAY_DIR/etc/profile.d/reproos-libpath.sh" \
       "$OVERLAY_DIR/usr/share/wayland-sessions" \
       "$OVERLAY_DIR/usr/local/sbin/repro-de-select.sh" \
       -exec touch -h --date="@$SOURCE_DATE_EPOCH" {} + 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Stage 8: sentinel + summary.
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = 0 ]; then
  cat > "$SENTINEL" <<EOF
DEM1 multi-DE composition applied.
Date: $(date -u +%Y-%m-%dT%H:%M:%SZ -d "@$SOURCE_DATE_EPOCH")
Overlay: $OVERLAY_DIR
Source: ubuntu-jammy (.deb harvest)

Composed DEs:
  - DE-H1 (Hyprland-equivalent, sway-as-Hyprland)
  - DE-G1 (GNOME 42)
  - DE-K1 (KDE Plasma 5.24)
Default DE (no GRUB cmdline gate): $DEFAULT_DE

Per-DE sentinels:
  /var/lib/reproos-de-hyprland-done
  /var/lib/reproos-de-gnome-done
  /var/lib/reproos-de-plasma-done

DEM1 planted:
  /etc/systemd/system/repro-de-select.service                              (boot-time DE selector oneshot)
  /etc/systemd/system/multi-user.target.wants/repro-de-select.service      (oneshot activation)
  /usr/local/sbin/repro-de-select.sh                                       (selector ExecStart)
  /etc/profile.d/reproos-libpath.sh                                        (union LD_LIBRARY_PATH; composed)
  /usr/share/wayland-sessions/hyprland.desktop                             (freedesktop canonical session)
  /usr/share/wayland-sessions/gnome.desktop                                (freedesktop canonical session)
  /usr/share/wayland-sessions/plasmawayland.desktop                        (freedesktop canonical session)

Removed (the selector owns these at boot):
  /etc/systemd/system/multi-user.target.wants/gdm.service
  /etc/systemd/system/multi-user.target.wants/sddm.service
  /etc/systemd/system/display-manager.service

Boot-time DE selection:
  repro.de=hyprland  -> no display-manager (autologin getty path)
  repro.de=gnome     -> gdm.service
  repro.de=plasma    -> sddm.service
  (none / invalid)    -> default ($DEFAULT_DE)

Next step:
  Pair with build-mvp-iso.sh stage 4k (MVP_INCLUDE_MULTI_DE=1) +
  recipes/reproos-iso/scripts/build-iso.sh (4-entry GRUB menu) to
  assemble the multi-DE ISO.
EOF

  touch -h --date="@$SOURCE_DATE_EPOCH" "$SENTINEL" 2>/dev/null || true
fi

log "DEM1 multi-DE composition DONE (default=$DEFAULT_DE dry_run=$DRY_RUN)"
exit 0

#!/usr/bin/env bash
# build-mvp-hyprland-rootfs.sh -- DE-H1 catalog -> overlay-plant driver.
#
# Reads recipes/catalog/linux/{sway,wlroots,foot,waybar,xkb-data,
# fontconfig-config,xdg-desktop-portal,xdg-desktop-portal-wlr,libelf1,
# libxcb1,libxcb-extras,libwayland-cursor,libseat,libinput,libpixman,
# libglvnd,libxkbregistry,libfcft}.json (18 catalogs) and for each:
#
#   1. Fetches the .debs into vendored-archives/linux/ (shared with DE0-G).
#   2. Verifies sha256 + size pins.
#   3. Extracts via dpkg-deb -x.
#   4. Verifies expected_files[] land under the extraction root.
#   5. Plants under $OVERLAY/opt/reproos-linux/store/<hash>/.
#   6. Creates SONAME symlinks for every shared_library entry.
#   7. Appends to /etc/ld.so.conf.d/00-reproos-linux.conf (the DE0-G
#      snippet) so the new libs land on the linker's search path.
#   8. Appends each catalog to /opt/reproos-linux/store/registry.json
#      sorted by name.
#
# AFTER the catalog pass, the script also plants the DE-H1
# compositor-config layer:
#
#   - /etc/hyprland.conf (the documented Hyprland config; minimal default).
#   - /etc/sway/config (the active sway config; translation of hyprland.conf).
#   - /etc/wayland-sessions/hyprland.desktop (SDDM/GDM session entry).
#   - /usr/local/bin/repro-start-hyprland.sh (session entry-point shim).
#   - /etc/profile.d/xkb-data.sh + /etc/profile.d/glvnd.sh (XKB_CONFIG_ROOT
#     + __EGL_VENDOR_LIBRARY_DIRS exports so libxkbcommon and libglvnd find
#     the overlay-planted data paths).
#
# Sentinel: /var/lib/reproos-de-hyprland-done.
#
# Catalog skip rule.
#
#   Any catalog whose provisioning_methods[].kind == 'upstream-source-tarball'
#   is SKIPPED. Today that's hyprland.json (the upstream Hyprland v0.41.2
#   source tarball, advisory-only — see docs/wayland-de-hyprland.md).
#
# Composition with DE0-G.
#
#   This script calls build-linux-graphics-stack.sh FIRST (DE0-G base)
#   if its sentinel is missing. The DE0-G layer plants Mesa + libdrm +
#   libwayland + libxkbcommon + fontconfig + dejavu-fonts; DE-H1's compositor
#   stack composes on top. DE0-G's sentinel makes the second invocation
#   a no-op.
#
# Usage
# -----
#
#   build-mvp-hyprland-rootfs.sh
#     [--overlay-dir <path>]    # default: build/de-h1-mvp/overlay
#     [--catalog-root <path>]   # default: recipes/catalog/linux/
#     [--vendored <path>]       # default: shared with DE0-G
#     [--allow-online]          # permit curl fetch when .deb missing
#     [--skip-de0-g]            # don't call build-linux-graphics-stack.sh
#                               #   (assume DE0-G already applied)
#     [--dry-run]
#     [--verbose]
#
# Exit codes:
#   0    success
#   1    argument / preflight error
#   2    catalog file missing / malformed JSON
#   3    .deb sha256 / size mismatch
#   4    expected_files[] entry missing from extracted .deb
#   5    overlay write failure

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CATALOG_ROOT="$REPO_ROOT/recipes/catalog/linux"
OVERLAY_DIR="${DE_H1_OVERLAY_DIR:-$REPO_ROOT/build/de-h1-mvp/overlay}"
VENDORED_DIR="${DE_H1_VENDORED_DIR:-$SCRIPT_DIR/vendored-archives/linux}"
ALLOW_ONLINE=0
SKIP_DE0_G=0
DRY_RUN=0
VERBOSE=0

# When dot-sourced from a parent driver (build-mvp-iso.sh stage 4h),
# honour the parent's vars without forcing flags.
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
    --skip-de0-g)     SKIP_DE0_G=1;        shift ;;
    --dry-run)        DRY_RUN=1;           shift ;;
    --verbose)        VERBOSE=1;           shift ;;
    -h|--help)
      sed -n '1,/^set -euo pipefail$/p' "$0" | sed -n '/^#/p' >&2
      exit 0 ;;
    *) echo "[de-h1][error] unknown arg: $1" >&2; exit 1 ;;
  esac
done

log()  { echo "[de-h1] $*" >&2; }
vlog() { [ "$VERBOSE" = 1 ] && echo "[de-h1][verbose] $*" >&2 || true; }
die()  { echo "[de-h1][error] $*" >&2; exit "${2:-1}"; }

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

SENTINEL="$OVERLAY_DIR/var/lib/reproos-de-hyprland-done"
if [ "$DRY_RUN" = 0 ] && [ -f "$SENTINEL" ]; then
  log "sentinel present ($SENTINEL); skipping (idempotent no-op)"
  exit 0
fi

if [ "$DRY_RUN" = 0 ]; then
  mkdir -p "$OVERLAY_DIR" "$VENDORED_DIR" \
           "$OVERLAY_DIR/opt/reproos-linux/store" \
           "$OVERLAY_DIR/etc/ld.so.conf.d" \
           "$OVERLAY_DIR/etc/profile.d" \
           "$OVERLAY_DIR/etc/wayland-sessions" \
           "$OVERLAY_DIR/etc/sway" \
           "$OVERLAY_DIR/usr/local/bin" \
           "$OVERLAY_DIR/var/lib"
fi

# ---------------------------------------------------------------------------
# Compose with DE0-G.
# ---------------------------------------------------------------------------

if [ "$SKIP_DE0_G" = 0 ]; then
  DE0_G_SENTINEL="$OVERLAY_DIR/var/lib/reproos-de0-graphics-done"
  if [ ! -f "$DE0_G_SENTINEL" ]; then
    log "DE0-G base missing; composing build-linux-graphics-stack.sh"
    DE0_G_SH="$SCRIPT_DIR/build-linux-graphics-stack.sh"
    [ -f "$DE0_G_SH" ] || die "DE0-G builder missing: $DE0_G_SH" 1
    DE0_G_ARGS=( --overlay-dir "$OVERLAY_DIR" --vendored "$VENDORED_DIR" )
    [ "$ALLOW_ONLINE" = 1 ] && DE0_G_ARGS+=( --allow-online )
    [ "$DRY_RUN" = 1 ] && DE0_G_ARGS+=( --dry-run )
    [ "$VERBOSE" = 1 ] && DE0_G_ARGS+=( --verbose )
    bash "$DE0_G_SH" "${DE0_G_ARGS[@]}" 2>&1 | sed 's/^/[de-h1]   /'
  else
    log "DE0-G base already applied (sentinel present): $DE0_G_SENTINEL"
  fi
fi

# ---------------------------------------------------------------------------
# Helpers (lifted from build-linux-graphics-stack.sh; identical shape).
# ---------------------------------------------------------------------------

jget() {
  python3 - "$1" <<PYEOF
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print($2)
PYEOF
}

catalog_hash() {
  local name="$1" version="$2" snapshot="$3"
  printf '%s|%s|%s' "$name" "$version" "$snapshot" | sha256sum | awk '{print substr($1,1,16)}'
}

# ---------------------------------------------------------------------------
# Catalog set for DE-H1. ORDER MATTERS for registry.json byte-stability
# (sorted by name). We hand-list rather than glob so DE0-G's six catalogs
# (mesa/libdrm/libwayland/libxkbcommon/fontconfig/dejavu-fonts) are
# excluded.
# ---------------------------------------------------------------------------

DE_H1_CATALOG_NAMES=(
  fontconfig-config
  foot
  hyprland
  libelf1
  libfcft
  libglvnd
  libinput
  libpixman
  libseat
  libwayland-cursor
  libxcb-extras
  libxcb1
  libxkbregistry
  sway
  waybar
  wlroots
  xdg-desktop-portal
  xdg-desktop-portal-wlr
  xkb-data
)

CATALOGS=()
for name in "${DE_H1_CATALOG_NAMES[@]}"; do
  p="$CATALOG_ROOT/$name.json"
  [ -f "$p" ] || die "catalog missing: $p" 2
  CATALOGS+=("$p")
done

log "processing ${#CATALOGS[@]} catalog(s) from $CATALOG_ROOT (overlay=$OVERLAY_DIR, dry-run=$DRY_RUN)"

LDCONF="$OVERLAY_DIR/etc/ld.so.conf.d/00-reproos-linux.conf"
# DE0-G already initialized this file; we append. If DE0-G was skipped
# (--skip-de0-g) and the file doesn't exist, create it now.
if [ "$DRY_RUN" = 0 ] && [ ! -f "$LDCONF" ]; then
  cat > "$LDCONF" <<'EOF'
# DE-H1: Wayland-DE Linux graphics stack (DE0-G + DE-H1 catalog tiers).
EOF
fi

# Append a DE-H1 marker.
if [ "$DRY_RUN" = 0 ]; then
  echo "" >> "$LDCONF"
  echo "# DE-H1: Hyprland-equivalent (sway-as-Hyprland) compositor stack." >> "$LDCONF"
fi

REG_PATH="$OVERLAY_DIR/opt/reproos-linux/store/registry.json"
if [ "$DRY_RUN" = 0 ] && [ ! -f "$REG_PATH" ]; then
  echo '[]' > "$REG_PATH"
fi

TOTAL_BYTES=0
TOTAL_FILES=0
PLANTED_COUNT=0
SKIPPED_COUNT=0

for catalog in "${CATALOGS[@]}"; do
  cat_name="$(jget "$catalog" 'd["package"]["name"]')"
  cat_version="$(jget "$catalog" 'd["package"]["version"]')"
  cat_snapshot="$(jget "$catalog" 'd["package"]["snapshot"]')"
  cat_runtime="$(jget "$catalog" 'd["runtime"]')"
  cat_source="$(jget "$catalog" 'd["package_source"]')"

  [ "$cat_runtime" = "linux" ] || die "catalog $cat_name: runtime != linux ($cat_runtime)" 2

  # Skip rule: advisory-only entries (upstream-source-tarball).
  pm_kind="$(jget "$catalog" 'd["provisioning_methods"][0]["kind"]')"
  if [ "$pm_kind" = "upstream-source-tarball" ]; then
    log "  $cat_name $cat_version: SKIPPED (kind=$pm_kind; advisory only)"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  [ "$cat_source" = "ubuntu-jammy" ] || die "catalog $cat_name: package_source != ubuntu-jammy ($cat_source)" 2

  cat_hash="$(catalog_hash "$cat_name" "$cat_version" "$cat_snapshot")"
  store_dir="$OVERLAY_DIR/opt/reproos-linux/store/$cat_hash"

  log "  $cat_name $cat_version: hash=$cat_hash"

  if [ "$DRY_RUN" = 0 ]; then
    rm -rf "$store_dir"
    mkdir -p "$store_dir"
  fi

  payload_count="$(jget "$catalog" 'len(d["payload_files"])')"
  vlog "  $cat_name: payload_files = $payload_count deb(s)"

  file_count=0

  i=0
  while [ "$i" -lt "$payload_count" ]; do
    deb_pkg="$(jget "$catalog" "d['payload_files'][$i]['deb_pkg']")"
    deb_url="$(jget "$catalog" "d['payload_files'][$i]['deb_url']")"
    deb_sha="$(jget "$catalog" "d['payload_files'][$i]['deb_sha256']")"
    deb_size="$(jget "$catalog" "d['payload_files'][$i]['deb_size_bytes']")"

    deb_basename="$(basename "$deb_url")"
    deb_path="$VENDORED_DIR/$deb_basename"

    if [ ! -f "$deb_path" ]; then
      if [ "$ALLOW_ONLINE" = 1 ]; then
        log "  $cat_name: fetching $deb_url"
        mkdir -p "$VENDORED_DIR"
        curl -fsSL -o "$deb_path.part" "$deb_url" || die "$cat_name: curl failed for $deb_url" 1
        mv "$deb_path.part" "$deb_path"
      else
        die "$cat_name: .deb missing at $deb_path (use --allow-online or pre-populate)" 1
      fi
    fi

    got_sha="$(sha256sum "$deb_path" | awk '{print $1}')"
    [ "$got_sha" = "$deb_sha" ] || die "$cat_name/$deb_pkg: sha mismatch (exp $deb_sha got $got_sha)" 3
    got_size="$(stat -c '%s' "$deb_path")"
    [ "$got_size" = "$deb_size" ] || die "$cat_name/$deb_pkg: size mismatch (exp $deb_size got $got_size)" 3
    vlog "  $cat_name/$deb_pkg: sha + size verified"

    extract_tmp="$(mktemp -d -t "de-h1-extract-$cat_name-$deb_pkg.XXXXXX")"
    dpkg-deb -x "$deb_path" "$extract_tmp" || die "$cat_name/$deb_pkg: dpkg-deb -x failed" 1

    # xkb-data needs the FULL tree planted (not just the 9 gated files)
    # because libxkbcommon walks the directories at runtime. Same for
    # waybar's etc/xdg/waybar/* and fontconfig-config's etc/fonts/conf.avail/*.
    # For those three catalogs we copy the full extraction; for the rest
    # we copy only expected_files[] (efficiency).
    case "$cat_name" in
      xkb-data|fontconfig-config|waybar)
        if [ "$DRY_RUN" = 0 ]; then
          cp -a "$extract_tmp"/. "$store_dir/"
        fi
        ;;
    esac

    ef_count="$(jget "$catalog" "len(d['payload_files'][$i]['expected_files'])")"
    j=0
    while [ "$j" -lt "$ef_count" ]; do
      ef_kind="$(jget "$catalog" "d['payload_files'][$i]['expected_files'][$j]['kind']")"
      ef_path="$(jget "$catalog" "d['payload_files'][$i]['expected_files'][$j]['path']")"
      ef_soname="$(jget "$catalog" "d['payload_files'][$i]['expected_files'][$j].get('soname_link','')")"

      src="$extract_tmp/$ef_path"
      if [ ! -f "$src" ]; then
        rm -rf "$extract_tmp"
        die "$cat_name/$deb_pkg: expected file missing in archive: $ef_path" 4
      fi

      if [ "$DRY_RUN" = 0 ]; then
        dst="$store_dir/$ef_path"
        if [ ! -f "$dst" ]; then
          mkdir -p "$(dirname "$dst")"
          cp -a "$src" "$dst"
        fi
        case "$ef_kind" in
          binary)
            chmod +x "$dst"
            # DE-H2 cascade B fix: plant a /usr/local/bin/<name>
            # symlink pointing at the store binary so the autologin
            # shell finds it on PATH. Only do this for binaries that
            # live under usr/bin/ or usr/sbin/ in the store; libexec
            # binaries are not PATH-visible by convention.
            case "$ef_path" in
              usr/bin/*|usr/sbin/*)
                bin_name="$(basename "$ef_path")"
                ln_target="/opt/reproos-linux/store/$cat_hash/$ef_path"
                ln_path="$OVERLAY_DIR/usr/local/bin/$bin_name"
                ln -sf "$ln_target" "$ln_path"
                vlog "  $cat_name/$deb_pkg: bin /usr/local/bin/$bin_name -> $ln_target"
                ;;
            esac
            ;;
          shared_library)
            chmod 0644 "$dst"
            if [ -n "$ef_soname" ]; then
              soname_dst="$store_dir/$ef_soname"
              mkdir -p "$(dirname "$soname_dst")"
              # Remove the SONAME file if dpkg-deb -x already extracted
              # it (xkb-data / waybar / fontconfig-config full-copy case);
              # we then replace with a relative symlink for relocatability.
              rm -f "$soname_dst"
              ln -sf "$(basename "$ef_path")" "$soname_dst"
              vlog "  $cat_name/$deb_pkg: soname $ef_soname -> $(basename "$ef_path")"
            fi
            ;;
        esac
      fi
      file_count=$((file_count + 1))
      vlog "  $cat_name/$deb_pkg: planted ($ef_kind) $ef_path"
      j=$((j + 1))
    done

    rm -rf "$extract_tmp"
    TOTAL_BYTES=$((TOTAL_BYTES + deb_size))
    i=$((i + 1))
  done

  TOTAL_FILES=$((TOTAL_FILES + file_count))
  PLANTED_COUNT=$((PLANTED_COUNT + 1))

  # ld.so.conf.d snippet line for this catalog (libs only).
  if [ "$DRY_RUN" = 0 ]; then
    if [ -d "$store_dir/usr/lib/x86_64-linux-gnu" ]; then
      ldconf_line="/opt/reproos-linux/store/$cat_hash/usr/lib/x86_64-linux-gnu"
      # Avoid duplicate lines if rerun without sentinel.
      grep -qxF "$ldconf_line" "$LDCONF" 2>/dev/null || echo "$ldconf_line" >> "$LDCONF"
    fi
  fi

  # Append registry entry.
  if [ "$DRY_RUN" = 0 ]; then
    python3 - "$REG_PATH" "$catalog" "$cat_hash" "$file_count" <<'PYEOF'
import json, sys
reg_path, catalog_path, cat_hash, file_count = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
with open(reg_path) as f:
    reg = json.load(f)
with open(catalog_path) as f:
    c = json.load(f)
entry = {
    "name": c["package"]["name"],
    "version": c["package"]["version"],
    "snapshot": c["package"]["snapshot"],
    "package_source": c["package_source"],
    "store_hash": cat_hash,
    "store_path": f"/opt/reproos-linux/store/{cat_hash}",
    "debs": sorted(
        [
            {"deb_pkg": p["deb_pkg"], "deb_sha256": p["deb_sha256"], "deb_size_bytes": p["deb_size_bytes"]}
            for p in c["payload_files"]
        ],
        key=lambda x: x["deb_pkg"]),
    "file_count": file_count,
    "dependency_closure": c["dependency_closure"],
    "linux_version_banner": c.get("linux_version_banner", ""),
}
# Replace existing entry with same name (idempotency when sentinel removed).
reg = [e for e in reg if e.get("name") != entry["name"]]
reg.append(entry)
reg.sort(key=lambda x: x["name"])
with open(reg_path, "w") as f:
    json.dump(reg, f, indent=2, sort_keys=True)
    f.write("\n")
PYEOF
  fi

  log "  $cat_name: planted $file_count file(s) under $store_dir"
done

# ---------------------------------------------------------------------------
# DE-H1 compositor-config layer.
#
# /etc/hyprland.conf : documented Hyprland config (minimal default).
# /etc/sway/config   : active sway config (1:1 translation).
# /etc/wayland-sessions/hyprland.desktop : SDDM session entry.
# /usr/local/bin/repro-start-hyprland.sh : session entry shim.
# /etc/profile.d/xkb-data.sh + glvnd.sh  : runtime env exports.
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = 0 ]; then
  # Resolve the actual store hashes we need for the env exports.
  xkb_hash="$(catalog_hash xkb-data "$(jget "$CATALOG_ROOT/xkb-data.json" 'd["package"]["version"]')" "$(jget "$CATALOG_ROOT/xkb-data.json" 'd["package"]["snapshot"]')")"
  mesa_hash="$(catalog_hash mesa "$(jget "$CATALOG_ROOT/mesa.json" 'd["package"]["version"]')" "$(jget "$CATALOG_ROOT/mesa.json" 'd["package"]["snapshot"]')")"

  log "planting /etc/hyprland.conf"
  cat > "$OVERLAY_DIR/etc/hyprland.conf" <<'EOF'
# DE-H1: documented Hyprland configuration.
#
# The PLANTED compositor is sway (jammy-native wlroots compositor; see
# docs/wayland-de-hyprland.md "Why sway (not Hyprland)"). When upstream
# Hyprland v0.41.x is built from source in a future milestone, the
# upstream Hyprland binary reads THIS file directly and /etc/sway/config
# becomes vestigial.

monitor=,preferred,auto,1
exec-once = waybar
bind = SUPER, Return, exec, foot
bind = SUPER, Q, killactive
bind = SUPER, M, exit
EOF

  log "planting /etc/sway/config (1:1 translation of /etc/hyprland.conf)"
  cat > "$OVERLAY_DIR/etc/sway/config" <<'EOF'
# DE-H1: sway config translating /etc/hyprland.conf 1:1.
#
# Edit /etc/hyprland.conf as the source of truth; the build script
# regenerates this file from the catalog mapping. When upstream Hyprland
# is planted in a future milestone, this file becomes vestigial.

# monitor=,preferred,auto,1
output * mode preferred

# exec-once = waybar
exec waybar

# bind = SUPER, Return, exec, foot
bindsym Mod4+Return exec foot

# bind = SUPER, Q, killactive
bindsym Mod4+q kill

# bind = SUPER, M, exit
bindsym Mod4+m exit
EOF

  log "planting /etc/wayland-sessions/hyprland.desktop"
  cat > "$OVERLAY_DIR/etc/wayland-sessions/hyprland.desktop" <<'EOF'
[Desktop Entry]
Name=Hyprland
Comment=ReproOS Hyprland-equivalent Wayland session (DE-H1)
Exec=/usr/local/bin/repro-start-hyprland.sh
Type=Application
DesktopNames=Hyprland
EOF

  log "planting /usr/local/bin/repro-start-hyprland.sh"
  cat > "$OVERLAY_DIR/usr/local/bin/repro-start-hyprland.sh" <<'EOF'
#!/usr/bin/env bash
# DE-H1 Wayland session entry shim.
#
# Sources DE0-S session env, honours REPRO_HEADLESS, exec's the planted
# compositor (sway today; upstream Hyprland in a future milestone).

set -e

# Source any /etc/profile.d/*.sh exports that the catalog tier needs
# (XKB_CONFIG_ROOT, __EGL_VENDOR_LIBRARY_DIRS). Per DE0-S the user shell
# already does this for interactive logins; explicit re-source here covers
# greeter/SDDM-style non-interactive exec paths.
if [ -d /etc/profile.d ]; then
  for f in /etc/profile.d/*.sh; do
    [ -r "$f" ] && . "$f"
  done
fi

# XDG_RUNTIME_DIR comes from logind (DE0-S). Sanity-check.
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  echo "[repro-start-hyprland] WARN: XDG_RUNTIME_DIR unset; logind may not be running" >&2
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"
fi

# Headless mode: WLR_BACKENDS=headless skips DRM, renders to off-screen
# pixman surface. Used by DE-H2's vm-harness boot test when the DRM
# backend doesn't behave on Hyper-V SyntheticVideo.
if [ "${REPRO_HEADLESS:-0}" = "1" ]; then
  export WLR_BACKENDS=headless
  export WLR_LIBINPUT_NO_DEVICES=1
fi

# Dispatch to the planted compositor.
#   DE-H2 cascade B fix: hardcode /usr/local/bin/<name> so the shim does
#   not depend on PATH being correctly set in the autologin shell. The
#   DE0-G + DE-H1 builders plant /usr/local/bin/{sway,swaymsg,foot,waybar}
#   as symlinks into /opt/reproos-linux/store/<hash>/usr/bin/ via the
#   post-extract binary-symlink farm.
#
#   Future: when /usr/local/bin/Hyprland exists (upstream Hyprland built
#   from source), exec it directly. For now: sway.
if [ -x /usr/local/bin/Hyprland ]; then
  exec /usr/local/bin/Hyprland "$@"
elif [ -x /usr/local/bin/sway ]; then
  exec /usr/local/bin/sway "$@"
elif command -v Hyprland >/dev/null 2>&1; then
  exec Hyprland "$@"
elif command -v sway >/dev/null 2>&1; then
  exec sway "$@"
else
  echo "[repro-start-hyprland] FATAL: no compositor on PATH or at /usr/local/bin/{sway,Hyprland}" >&2
  exit 127
fi
EOF
  chmod +x "$OVERLAY_DIR/usr/local/bin/repro-start-hyprland.sh"

  log "planting /etc/profile.d/xkb-data.sh"
  cat > "$OVERLAY_DIR/etc/profile.d/xkb-data.sh" <<EOF
# DE-H1: point libxkbcommon at the overlay-planted xkb-data tree.
export XKB_CONFIG_ROOT="/opt/reproos-linux/store/$xkb_hash/usr/share/X11/xkb"
EOF

  log "planting /etc/profile.d/glvnd.sh"
  cat > "$OVERLAY_DIR/etc/profile.d/glvnd.sh" <<EOF
# DE-H1: point libglvnd's libEGL.so.1 at Mesa's vendor json.
export __EGL_VENDOR_LIBRARY_DIRS="/opt/reproos-linux/store/$mesa_hash/usr/share/glvnd/egl_vendor.d"
EOF

  # Pin mtimes for determinism. /usr/local/bin includes both the shim
  # (repro-start-hyprland.sh) and the cascade-B store -> /usr/local/bin
  # binary-symlink farm planted in the per-catalog loop above.
  find "$OVERLAY_DIR/opt/reproos-linux" \
       "$OVERLAY_DIR/etc/ld.so.conf.d" \
       "$OVERLAY_DIR/etc/hyprland.conf" \
       "$OVERLAY_DIR/etc/sway" \
       "$OVERLAY_DIR/etc/wayland-sessions" \
       "$OVERLAY_DIR/etc/profile.d" \
       "$OVERLAY_DIR/usr/local/bin" \
       -exec touch -h --date="@$SOURCE_DATE_EPOCH" {} + 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Sentinel + summary.
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = 0 ]; then
  cat > "$SENTINEL" <<EOF
DE-H1 Hyprland-equivalent (sway-as-Hyprland) compositor tier applied.
Date: $(date -u +%Y-%m-%dT%H:%M:%SZ -d "@$SOURCE_DATE_EPOCH")
Overlay: $OVERLAY_DIR
Source: ubuntu-jammy (.deb harvest)

Planted catalogs ($PLANTED_COUNT):
$(python3 -c "
import json
reg = json.load(open('$REG_PATH'))
de_h1_names = {'fontconfig-config','foot','libelf1','libfcft','libglvnd',
               'libinput','libpixman','libseat','libwayland-cursor',
               'libxcb-extras','libxcb1','libxkbregistry','sway','waybar',
               'wlroots','xdg-desktop-portal','xdg-desktop-portal-wlr','xkb-data'}
for e in reg:
    if e['name'] in de_h1_names:
        print(f\"  - {e['name']:24} {e['version']:32}  hash={e['store_hash']}  files={e['file_count']}\")
")

Skipped catalogs ($SKIPPED_COUNT, advisory-only):
  - hyprland               v0.41.2  (upstream-source-tarball; see hyprland.json)

Totals (DE-H1 layer only):
  .deb closure size: $TOTAL_BYTES bytes (~$((TOTAL_BYTES / 1024)) KB)
  planted files:     $TOTAL_FILES

Planted config:
  /etc/hyprland.conf                       (documented Hyprland config)
  /etc/sway/config                         (active sway config, 1:1 translation)
  /etc/wayland-sessions/hyprland.desktop   (SDDM session entry)
  /usr/local/bin/repro-start-hyprland.sh   (session entry shim)
  /etc/profile.d/xkb-data.sh               (XKB_CONFIG_ROOT export)
  /etc/profile.d/glvnd.sh                  (__EGL_VENDOR_LIBRARY_DIRS export)

Next step:
  DE-H2 : vm-harness Hyper-V boot test (boots ISO, autologin, exec
          repro-start-hyprland.sh, assert compositor up).
EOF

  touch -h --date="@$SOURCE_DATE_EPOCH" "$SENTINEL" 2>/dev/null || true
fi

log "DE-H1 overlay-plant DONE (planted=$PLANTED_COUNT skipped=$SKIPPED_COUNT files=$TOTAL_FILES bytes=$TOTAL_BYTES dry_run=$DRY_RUN)"
exit 0

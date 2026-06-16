#!/usr/bin/env bash
# build-mvp-plasma-rootfs.sh -- DE-K1 catalog -> overlay-plant driver.
#
# Reads the 30 DE-K1 catalog JSONs from recipes/catalog/linux/ and for
# each:
#
#   1. Fetches the .debs into vendored-archives/linux/ (shared with DE0-G
#      / DE-H1 / DE-G1).
#   2. Verifies sha256 + size pins.
#   3. Extracts via dpkg-deb -x.
#   4. Verifies expected_files[] land under the extraction root.
#   5. Plants under $OVERLAY/opt/reproos-linux/store/<hash>/.
#   6. Creates SONAME symlinks for every shared_library entry whose
#      `soname_link` is set.
#   7. Appends to /etc/ld.so.conf.d/00-reproos-linux.conf (the DE0-G
#      snippet), including the Qt 5 plugin sub-dir
#      usr/lib/x86_64-linux-gnu/qt5/plugins/kwin/ (parallel to DE-G1's
#      mutter-10/ sub-dir).
#   8. Appends each catalog to /opt/reproos-linux/store/registry.json
#      sorted by name.
#
# AFTER the catalog pass, plants the DE-K1 Plasma-config layer:
#
#   - /etc/sddm.conf : autologin as repro, Wayland session.
#   - /etc/wayland-sessions/plasmawayland.desktop : SDDM session entry.
#   - /usr/local/bin/repro-start-plasma.sh : session entry shim.
#   - /etc/profile.d/plasma-qt.sh : QT_PLUGIN_PATH + QML2_IMPORT_PATH.
#   - /etc/systemd/system/multi-user.target.wants/sddm.service : symlink
#     activating SDDM at boot.
#   - /etc/systemd/system/display-manager.service : convention symlink.
#   - /var/lib/sddm : pre-created stateful dir for SDDM.
#
# AFTER the layer pass, refreshes the cascade-E env-export file
# (/etc/profile.d/reproos-libpath.sh) to include the new DE-K1 lib paths
# AND re-splices the /etc/profile profile.d sourcing block if absent
# (idempotent).
#
# Sentinel: /var/lib/reproos-de-plasma-done.
#
# Composition with DE0-G + DE-H1 + DE-G1.
#
#   This script calls build-linux-graphics-stack.sh FIRST (DE0-G base)
#   if its sentinel is missing. DE-H1 and DE-G1 are INDEPENDENT overlays
#   that compose without conflict. When build-mvp-iso.sh enables
#   MVP_INCLUDE_PLASMA=1 alongside HYPRLAND / GNOME, each runs in its
#   own gated stage; each is idempotent and only the compositor-config
#   layer differs.
#
# Usage
# -----
#
#   build-mvp-plasma-rootfs.sh
#     [--overlay-dir <path>]    # default: build/de-k1-mvp/overlay
#     [--catalog-root <path>]   # default: recipes/catalog/linux/
#     [--vendored <path>]       # default: shared with DE0-G/H1/G1
#     [--allow-online]          # permit curl fetch when .deb missing
#     [--skip-de0-g]            # don't call build-linux-graphics-stack.sh
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
OVERLAY_DIR="${DE_K1_OVERLAY_DIR:-$REPO_ROOT/build/de-k1-mvp/overlay}"
VENDORED_DIR="${DE_K1_VENDORED_DIR:-$SCRIPT_DIR/vendored-archives/linux}"
ALLOW_ONLINE=0
SKIP_DE0_G=0
DRY_RUN=0
VERBOSE=0

# When dot-sourced from a parent driver (build-mvp-iso.sh stage 4j),
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
    *) echo "[de-k1][error] unknown arg: $1" >&2; exit 1 ;;
  esac
done

log()  { echo "[de-k1] $*" >&2; }
vlog() { [ "$VERBOSE" = 1 ] && echo "[de-k1][verbose] $*" >&2 || true; }
die()  { echo "[de-k1][error] $*" >&2; exit "${2:-1}"; }

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

SENTINEL="$OVERLAY_DIR/var/lib/reproos-de-plasma-done"
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
           "$OVERLAY_DIR/etc" \
           "$OVERLAY_DIR/etc/systemd/system/multi-user.target.wants" \
           "$OVERLAY_DIR/usr/local/bin" \
           "$OVERLAY_DIR/usr/local/sbin" \
           "$OVERLAY_DIR/var/lib" \
           "$OVERLAY_DIR/var/lib/sddm"
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
    bash "$DE0_G_SH" "${DE0_G_ARGS[@]}" 2>&1 | sed 's/^/[de-k1]   /'
  else
    log "DE0-G base already applied (sentinel present): $DE0_G_SENTINEL"
  fi
fi

# ---------------------------------------------------------------------------
# Helpers (lifted from build-mvp-gnome-rootfs.sh; identical shape).
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
# DE-K1 catalog set. ORDER MATTERS for registry.json byte-stability
# (sorted by name). DE0-G's six catalogs + DE-H1's 37 + DE-G1's 33 are
# excluded; this set is independent.
# ---------------------------------------------------------------------------

DE_K1_CATALOG_NAMES=(
  breeze
  kactivities
  kded
  kdelibs4support
  kf5-core
  kf5-declarative
  kf5-extras
  kf5-frameworks
  kf5-gui
  kf5-newstuff
  kf5-runner
  kio
  kwin
  kwin-libs
  libkscreenlocker
  libksysguard
  libxcb-extras-kde
  oxygen-sounds
  phonon
  plasma-desktop
  plasma-framework
  plasma-integration
  plasma-workspace
  qml-modules
  qt5-base
  qt5-declarative
  qt5-svg
  qt5-wayland
  sddm
  xdg-desktop-portal-kde
)

# Catalogs whose .debs need full-tree extract instead of expected_files
# minimum (sddm-theme-breeze ships /usr/share/sddm/themes/breeze/;
# plasma-desktop-data ships /usr/share/plasma/desktoptheme/; breeze-
# cursor-theme ships /usr/share/icons/breeze_cursors/; oxygen-sounds
# ships /usr/share/sounds/; qml-module-* ships the .qml + .so plugins
# under qt5/qml/).
DE_K1_FULL_EXTRACT_DEBS=(
  sddm-theme-breeze
  plasma-desktop-data
  breeze
  breeze-cursor-theme
  oxygen-sounds
  qml-module-qtquick2
  qml-module-qtquick-window2
  qml-module-qtquick-layouts
  qml-module-qtquick-controls
  qml-module-qtquick-controls2
  qml-module-qtquick-templates2
  qml-module-qtquick-dialogs
  qml-module-qt-labs-folderlistmodel
  qml-module-qt-labs-settings
  qml-module-org-kde-kirigami2
  qml-module-org-kde-kquickcontrols
  qml-module-org-kde-kquickcontrolsaddons
  qml-module-org-kde-kwindowsystem
  qml-module-org-kde-kcoreaddons
  qml-module-org-kde-solid
  qml-module-org-kde-draganddrop
  plasma-framework
  plasma-workspace
  kwin-common
  kio
)

deb_needs_full_extract() {
  local n="$1"
  for d in "${DE_K1_FULL_EXTRACT_DEBS[@]}"; do
    [ "$d" = "$n" ] && return 0
  done
  return 1
}

CATALOGS=()
for name in "${DE_K1_CATALOG_NAMES[@]}"; do
  p="$CATALOG_ROOT/$name.json"
  [ -f "$p" ] || die "catalog missing: $p" 2
  CATALOGS+=("$p")
done

log "processing ${#CATALOGS[@]} catalog(s) from $CATALOG_ROOT (overlay=$OVERLAY_DIR, dry-run=$DRY_RUN)"

LDCONF="$OVERLAY_DIR/etc/ld.so.conf.d/00-reproos-linux.conf"
# DE0-G + (optionally) DE-H1 + DE-G1 already initialized this file; we
# append. If all were skipped, create now.
if [ "$DRY_RUN" = 0 ] && [ ! -f "$LDCONF" ]; then
  cat > "$LDCONF" <<'EOF'
# DE-K1: KDE Plasma 5.24 stack on top of DE0-G.
EOF
fi

if [ "$DRY_RUN" = 0 ]; then
  echo "" >> "$LDCONF"
  echo "# DE-K1: KDE Plasma 5.24 stack (sddm + kwin + plasmashell + 27 support catalogs)." >> "$LDCONF"
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

    extract_tmp="$(mktemp -d -t "de-k1-extract-$cat_name-$deb_pkg.XXXXXX")"
    dpkg-deb -x "$deb_path" "$extract_tmp" || die "$cat_name/$deb_pkg: dpkg-deb -x failed" 1

    # Full-tree extract for data debs (themes / icons / qml plugins).
    if deb_needs_full_extract "$deb_pkg"; then
      if [ "$DRY_RUN" = 0 ]; then
        cp -a "$extract_tmp"/. "$store_dir/"
      fi
    fi

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
            # DE-H1/DE-G1 cascade B inherit: plant /usr/local/bin/<name>
            # symlinks so the autologin shell finds binaries on PATH.
            case "$ef_path" in
              usr/bin/*)
                bin_name="$(basename "$ef_path")"
                ln_target="/opt/reproos-linux/store/$cat_hash/$ef_path"
                ln_path="$OVERLAY_DIR/usr/local/bin/$bin_name"
                ln -sf "$ln_target" "$ln_path"
                vlog "  $cat_name/$deb_pkg: bin /usr/local/bin/$bin_name -> $ln_target"
                ;;
              usr/sbin/*)
                bin_name="$(basename "$ef_path")"
                ln_target="/opt/reproos-linux/store/$cat_hash/$ef_path"
                ln_path="$OVERLAY_DIR/usr/local/sbin/$bin_name"
                ln -sf "$ln_target" "$ln_path"
                vlog "  $cat_name/$deb_pkg: sbin /usr/local/sbin/$bin_name -> $ln_target"
                ;;
            esac
            ;;
          shared_library)
            chmod 0644 "$dst"
            if [ -n "$ef_soname" ]; then
              soname_dst="$store_dir/$ef_soname"
              mkdir -p "$(dirname "$soname_dst")"
              # Remove if a full-extract already placed it; replace with
              # a relative symlink for relocatability.
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

  # ld.so.conf.d snippet line for this catalog (libs only). Includes:
  #   - usr/lib/x86_64-linux-gnu/                  (canonical)
  #   - lib/x86_64-linux-gnu/                       (legacy; symmetry)
  #   - usr/lib/x86_64-linux-gnu/qt5/plugins/      (Qt 5 plugin dir; NEW)
  #   - usr/lib/x86_64-linux-gnu/qt5/plugins/kwin/ (KWin plugin sub-dir; NEW)
  #   - usr/lib/x86_64-linux-gnu/qt5/qml/          (QML import root; NEW)
  if [ "$DRY_RUN" = 0 ]; then
    for libdir in "usr/lib/x86_64-linux-gnu" \
                  "lib/x86_64-linux-gnu" \
                  "usr/lib/x86_64-linux-gnu/qt5/plugins" \
                  "usr/lib/x86_64-linux-gnu/qt5/plugins/kwin" \
                  "usr/lib/x86_64-linux-gnu/qt5/qml"; do
      if [ -d "$store_dir/$libdir" ]; then
        ldconf_line="/opt/reproos-linux/store/$cat_hash/$libdir"
        grep -qxF "$ldconf_line" "$LDCONF" 2>/dev/null || echo "$ldconf_line" >> "$LDCONF"
      fi
    done
  fi

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
# DE-K1 Plasma-config layer.
#
# /etc/sddm.conf                                  autologin + Wayland.
# /etc/wayland-sessions/plasmawayland.desktop     SDDM session entry.
# /usr/local/bin/repro-start-plasma.sh            session entry shim.
# /etc/profile.d/plasma-qt.sh                     QT_PLUGIN_PATH +
#                                                 QML2_IMPORT_PATH.
# /etc/systemd/system/multi-user.target.wants/sddm.service  SDDM activate.
# /etc/systemd/system/display-manager.service     KDE convention symlink.
# /var/lib/sddm/                                  stateful dir.
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = 0 ]; then
  # Resolve store hashes for the env exports + the sddm.service symlinks.
  sddm_hash="$(catalog_hash sddm "$(jget "$CATALOG_ROOT/sddm.json" 'd["package"]["version"]')" "$(jget "$CATALOG_ROOT/sddm.json" 'd["package"]["snapshot"]')")"
  kwin_hash="$(catalog_hash kwin "$(jget "$CATALOG_ROOT/kwin.json" 'd["package"]["version"]')" "$(jget "$CATALOG_ROOT/kwin.json" 'd["package"]["snapshot"]')")"

  log "planting /etc/sddm.conf"
  cat > "$OVERLAY_DIR/etc/sddm.conf" <<EOF
# DE-K1: SDDM autologin configuration.
#
# Per repro-start-plasma.sh, the DE0-S \`repro\` user (uid=1000) is the
# autologin target. DisplayServer=wayland forces the Wayland session
# path. Session matches /etc/wayland-sessions/plasmawayland.desktop.
# CompositorCommand pins kwin_wayland by absolute store path so the
# greeter does not depend on PATH being correctly set.

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
CompositorCommand=/opt/reproos-linux/store/$kwin_hash/usr/bin/kwin_wayland --no-lockscreen
EOF

  log "planting /etc/wayland-sessions/plasmawayland.desktop"
  cat > "$OVERLAY_DIR/etc/wayland-sessions/plasmawayland.desktop" <<'EOF'
[Desktop Entry]
Name=Plasma (Wayland)
Comment=ReproOS Plasma 5 Wayland session (DE-K1)
Exec=/usr/local/bin/repro-start-plasma.sh
TryExec=/usr/local/bin/startplasma-wayland
Type=Application
DesktopNames=KDE
EOF

  log "planting /usr/local/bin/repro-start-plasma.sh"
  cat > "$OVERLAY_DIR/usr/local/bin/repro-start-plasma.sh" <<'EOF'
#!/usr/bin/env bash
# DE-K1 Wayland session entry shim.
#
# Sources DE0-S session env, honours REPRO_HEADLESS, execs
# startplasma-wayland (which in turn execs ksmserver + plasmashell +
# the kded5 + kactivitymanagerd daemons).

set -e

# Source any /etc/profile.d/*.sh exports that the catalog tier needs
# (LD_LIBRARY_PATH, QT_PLUGIN_PATH, QML2_IMPORT_PATH, XDG_DATA_DIRS,
# XKB_CONFIG_ROOT).
if [ -d /etc/profile.d ]; then
  for f in /etc/profile.d/*.sh; do
    [ -r "$f" ] && . "$f"
  done
fi

# XDG_RUNTIME_DIR comes from logind (DE0-S). Sanity-check.
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  echo "[repro-start-plasma] WARN: XDG_RUNTIME_DIR unset; logind may not be running" >&2
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"
fi

# Headless mode for DE-K2 vm-harness boot under Hyper-V.
if [ "${REPRO_HEADLESS:-0}" = "1" ]; then
  export QT_QPA_PLATFORM=offscreen
  export KWIN_COMPOSE=O2
  export KWIN_X11_NO_SYNC_TO_VBLANK=1
  export WLR_LIBINPUT_NO_DEVICES=1
fi

# Cascade C lesson (DE-H1/DE-G1): start a session-bus dbus-daemon if one
# isn't already running. startplasma-wayland needs the session bus to
# auto-activate kded5 + kactivitymanagerd + klauncher + ksmserver.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  if command -v dbus-daemon >/dev/null 2>&1; then
    eval "$(dbus-daemon --session --fork --print-address=1 --print-pid=1 | awk 'NR==1{print "export DBUS_SESSION_BUS_ADDRESS="$0} NR==2{print "export DBUS_SESSION_BUS_PID="$0}')"
  fi
fi

# Plasma-specific env. KDE_FULL_SESSION + DESKTOP_SESSION are checked by
# many KF5 components to enable Plasma-specific code paths.
export KDE_FULL_SESSION=true
export DESKTOP_SESSION=plasmawayland
export XDG_CURRENT_DESKTOP=KDE
export XDG_SESSION_TYPE=wayland

# Pre-launch kactivitymanagerd + kded5 if the corresponding binaries are
# planted. startplasma-wayland will also autostart them via xdg-autostart,
# but doing it here pre-empts the race documented in the design memo
# (cascade C) where plasmashell aborts before its autostart triggers.
if command -v kactivitymanagerd >/dev/null 2>&1; then
  kactivitymanagerd &>/dev/null &
fi
if command -v kded5 >/dev/null 2>&1; then
  kded5 &>/dev/null &
fi

# Dispatch to startplasma-wayland (which execs ksmserver -> plasmashell).
if [ -x /usr/local/bin/startplasma-wayland ]; then
  exec /usr/local/bin/startplasma-wayland "$@"
elif command -v startplasma-wayland >/dev/null 2>&1; then
  exec startplasma-wayland "$@"
elif [ -x /usr/local/bin/kwin_wayland ]; then
  # Fallback: kwin_wayland standalone (no plasmashell; smoke only).
  exec /usr/local/bin/kwin_wayland --no-lockscreen "$@"
else
  echo "[repro-start-plasma] FATAL: no startplasma-wayland or kwin_wayland on PATH" >&2
  exit 127
fi
EOF
  chmod +x "$OVERLAY_DIR/usr/local/bin/repro-start-plasma.sh"

  log "planting /etc/profile.d/plasma-qt.sh"
  # Build the QT_PLUGIN_PATH + QML2_IMPORT_PATH colon-lists from the
  # store hashes the catalog tier just planted. We walk the registry
  # to be robust to catalog reorderings.
  QT_PLUGIN_PATHS=""
  QML_PATHS=""
  while IFS= read -r line; do
    case "$line" in
      ""|"#"*) continue ;;
    esac
    # Only include entries that point at qt5/plugins or qt5/qml.
    case "$line" in
      */qt5/plugins/kwin)
        # Sub-dir; already covered by parent qt5/plugins entry.
        ;;
      */qt5/plugins)
        QT_PLUGIN_PATHS="${QT_PLUGIN_PATHS:+$QT_PLUGIN_PATHS:}$line"
        ;;
      */qt5/qml)
        QML_PATHS="${QML_PATHS:+$QML_PATHS:}$line"
        ;;
    esac
  done < "$LDCONF"

  cat > "$OVERLAY_DIR/etc/profile.d/plasma-qt.sh" <<EOF
# DE-K1: Qt 5 + KF5 plugin / QML search paths.
#
# Qt's QPlatformIntegrationFactory walks QT_PLUGIN_PATH at startup to
# find the QPA backend (xcb / wayland / minimal / offscreen). Without
# this, Qt only checks /usr/lib/qt5/plugins which the R9 base does NOT
# ship.
#
# Plasma's plasmashell + krunner + kwin (when run via the QML scripting
# helper) walk QML2_IMPORT_PATH to resolve "import org.kde.*" and
# "import QtQuick" — the qml-modules catalog plants every required
# module under each store-dir's qt5/qml/ tree.
export QT_PLUGIN_PATH="$QT_PLUGIN_PATHS\${QT_PLUGIN_PATH:+:\$QT_PLUGIN_PATH}"
export QML2_IMPORT_PATH="$QML_PATHS\${QML2_IMPORT_PATH:+:\$QML2_IMPORT_PATH}"

# Plasma 5 needs XDG_DATA_DIRS to include the planted /usr/share trees
# (icons, plasma themes, mime types).
__dek1_extra_data=""
for hd in /opt/reproos-linux/store/*/usr/share; do
  if [ -d "\$hd" ]; then
    __dek1_extra_data="\${__dek1_extra_data:+\$__dek1_extra_data:}\$hd"
  fi
done
if [ -n "\$__dek1_extra_data" ]; then
  export XDG_DATA_DIRS="\${__dek1_extra_data}\${XDG_DATA_DIRS:+:\$XDG_DATA_DIRS}"
fi
unset __dek1_extra_data
EOF

  log "wiring sddm.service into multi-user.target.wants"
  ln -sf "/opt/reproos-linux/store/$sddm_hash/lib/systemd/system/sddm.service" \
         "$OVERLAY_DIR/etc/systemd/system/multi-user.target.wants/sddm.service"
  log "wiring /etc/systemd/system/display-manager.service convention symlink"
  ln -sf "/opt/reproos-linux/store/$sddm_hash/lib/systemd/system/sddm.service" \
         "$OVERLAY_DIR/etc/systemd/system/display-manager.service"

  # DE-H2 cascade E inheritance: refresh the LD_LIBRARY_PATH env-export
  # file with the union of DE0-G + DE-H1/G1/K1 lib paths.
  log "refreshing /etc/profile.d/reproos-libpath.sh (DE-H2 cascade E inherit)"
  LD_PATHS=""
  while IFS= read -r line; do
    case "$line" in
      ""|"#"*) continue ;;
      */qt5/qml) continue ;;  # QML import; not a regular lib search path.
    esac
    if [ -z "$LD_PATHS" ]; then
      LD_PATHS="$line"
    else
      LD_PATHS="$LD_PATHS:$line"
    fi
  done < "$LDCONF"
  cat > "$OVERLAY_DIR/etc/profile.d/reproos-libpath.sh" <<EOF
# DE-K1 + DE-G1 + DE-H1 + DE0-G: LD_LIBRARY_PATH for the catalog-
# planted store libs.
#
# The R9 from-source base ships no ldconfig / ld.so.cache so the
# /etc/ld.so.conf.d/*.conf entries are NOT consumed by the linker at
# binary launch. Exporting LD_LIBRARY_PATH gives the same effect at
# the user-shell level.
export LD_LIBRARY_PATH="$LD_PATHS\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
EOF

  log "splicing /etc/profile.d sourcing into /etc/profile (DE-H2 cascade E inherit)"
  PROFILE_FILE="$OVERLAY_DIR/etc/profile"
  if [ ! -f "$PROFILE_FILE" ]; then
    cat > "$PROFILE_FILE" <<'EOF'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export TERM=linux
umask 022
EOF
  fi
  # Honour any prior marker (DE-H1, DE-G1, or DE-K1 itself).
  if ! grep -qE "^# DE-(H1|G1|K1): source /etc/profile.d/\*\.sh$" "$PROFILE_FILE"; then
    cat >> "$PROFILE_FILE" <<'EOF'

# DE-K1: source /etc/profile.d/*.sh
# (The R9 base /etc/profile follows the POSIX contract that does not
# automatically source /etc/profile.d/*.sh; add it explicitly so the
# autologin user shell picks up the catalog-store env exports,
# including LD_LIBRARY_PATH and QT_PLUGIN_PATH.)
if [ -d /etc/profile.d ]; then
  for __f in /etc/profile.d/*.sh; do
    [ -r "$__f" ] && . "$__f"
  done
  unset __f
fi
EOF
  fi

  # Pre-create /var/lib/sddm with mode 0750 (the sddm user doesn't
  # exist at this stage; that's a DE-K2 boot-time concern).
  chmod 0750 "$OVERLAY_DIR/var/lib/sddm" 2>/dev/null || true

  find "$OVERLAY_DIR/opt/reproos-linux" \
       "$OVERLAY_DIR/etc/ld.so.conf.d" \
       "$OVERLAY_DIR/etc/sddm.conf" \
       "$OVERLAY_DIR/etc/wayland-sessions" \
       "$OVERLAY_DIR/etc/profile" \
       "$OVERLAY_DIR/etc/profile.d" \
       "$OVERLAY_DIR/etc/systemd/system" \
       "$OVERLAY_DIR/usr/local/bin" \
       "$OVERLAY_DIR/usr/local/sbin" \
       -exec touch -h --date="@$SOURCE_DATE_EPOCH" {} + 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Sentinel + summary.
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = 0 ]; then
  cat > "$SENTINEL" <<EOF
DE-K1 KDE Plasma 5.24 stack applied.
Date: $(date -u +%Y-%m-%dT%H:%M:%SZ -d "@$SOURCE_DATE_EPOCH")
Overlay: $OVERLAY_DIR
Source: ubuntu-jammy (.deb harvest)

Planted catalogs ($PLANTED_COUNT):
$(python3 -c "
import json
reg = json.load(open('$REG_PATH'))
de_k1_names = {'breeze','kactivities','kded','kdelibs4support','kf5-core',
               'kf5-declarative','kf5-extras','kf5-frameworks','kf5-gui',
               'kf5-newstuff','kf5-runner','kio','kwin','kwin-libs',
               'libkscreenlocker','libksysguard','libxcb-extras-kde',
               'oxygen-sounds','phonon','plasma-desktop','plasma-framework',
               'plasma-integration','plasma-workspace','qml-modules',
               'qt5-base','qt5-declarative','qt5-svg','qt5-wayland','sddm',
               'xdg-desktop-portal-kde'}
for e in reg:
    if e['name'] in de_k1_names:
        print(f\"  - {e['name']:24} {e['version']:32}  hash={e['store_hash']}  files={e['file_count']}\")
")

Skipped catalogs ($SKIPPED_COUNT, advisory-only): none

Totals (DE-K1 layer only):
  .deb closure size: $TOTAL_BYTES bytes (~$((TOTAL_BYTES / 1024)) KB / $((TOTAL_BYTES / 1024 / 1024)) MB)
  planted files:     $TOTAL_FILES

Planted config:
  /etc/sddm.conf                                                        (autologin SDDM config)
  /etc/wayland-sessions/plasmawayland.desktop                           (SDDM session entry)
  /usr/local/bin/repro-start-plasma.sh                                  (session entry shim)
  /etc/profile.d/plasma-qt.sh                                           (QT_PLUGIN_PATH + QML2_IMPORT_PATH)
  /etc/profile.d/reproos-libpath.sh                                     (LD_LIBRARY_PATH; refreshed)
  /etc/systemd/system/multi-user.target.wants/sddm.service              (SDDM activation)
  /etc/systemd/system/display-manager.service                           (KDE convention symlink)
  /var/lib/sddm/                                                        (sddm stateful dir)

Next step:
  DE-K2 : vm-harness Hyper-V Plasma boot test (boots ISO, autologin,
          exec repro-start-plasma.sh, assert kwin_wayland + plasmashell up).
EOF

  touch -h --date="@$SOURCE_DATE_EPOCH" "$SENTINEL" 2>/dev/null || true
fi

log "DE-K1 overlay-plant DONE (planted=$PLANTED_COUNT skipped=$SKIPPED_COUNT files=$TOTAL_FILES bytes=$TOTAL_BYTES dry_run=$DRY_RUN)"
exit 0

#!/usr/bin/env bash
# build-mvp-gnome-rootfs.sh -- DE-G1 catalog -> overlay-plant driver.
#
# Reads the 33 DE-G1 catalog JSONs from recipes/catalog/linux/ and for
# each:
#
#   1. Fetches the .debs into vendored-archives/linux/ (shared with DE0-G
#      and DE-H1).
#   2. Verifies sha256 + size pins.
#   3. Extracts via dpkg-deb -x.
#   4. Verifies expected_files[] land under the extraction root.
#   5. Plants under $OVERLAY/opt/reproos-linux/store/<hash>/.
#   6. Creates SONAME symlinks for every shared_library entry whose
#      `soname_link` is set.
#   7. Appends to /etc/ld.so.conf.d/00-reproos-linux.conf (the DE0-G +
#      DE-H1 snippet).
#   8. Appends each catalog to /opt/reproos-linux/store/registry.json
#      sorted by name.
#
# AFTER the catalog pass, plants the DE-G1 GNOME-config layer:
#
#   - /etc/gdm3/custom.conf : autologin as repro, WaylandEnable=true.
#   - /etc/wayland-sessions/gnome.desktop : gdm3 session entry.
#   - /usr/local/bin/repro-start-gnome.sh : session entry shim.
#   - /etc/profile.d/gnome-gsettings.sh : XDG_DATA_DIRS export.
#   - /etc/systemd/system/multi-user.target.wants/gdm.service : symlink
#     activating gdm at boot.
#   - /var/lib/gdm3 : pre-created stateful dir for gdm3.
#
# AFTER the layer pass, refreshes the cascade-E env-export file
# (/etc/profile.d/reproos-libpath.sh) to include the new DE-G1 lib paths
# AND re-splices the /etc/profile profile.d sourcing block if absent
# (idempotent).
#
# Sentinel: /var/lib/reproos-de-gnome-done.
#
# Composition with DE0-G + DE-H1.
#
#   This script calls build-linux-graphics-stack.sh FIRST (DE0-G base)
#   if its sentinel is missing. The DE-H1 compositor stack does NOT have
#   to be present — DE-G1 composes parallel to DE-H1 (both share the
#   DE0-G + DE-H1 hidden libs surfaced by the DE-H1 audit). When
#   build-mvp-iso.sh enables BOTH MVP_INCLUDE_HYPRLAND=1 and
#   MVP_INCLUDE_GNOME=1, the DE-H1 builder runs first (stage 4h) then
#   DE-G1 builder (stage 4i); each is idempotent and only the
#   compositor-config layer differs.
#
# Usage
# -----
#
#   build-mvp-gnome-rootfs.sh
#     [--overlay-dir <path>]    # default: build/de-g1-mvp/overlay
#     [--catalog-root <path>]   # default: recipes/catalog/linux/
#     [--vendored <path>]       # default: shared with DE0-G + DE-H1
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
OVERLAY_DIR="${DE_G1_OVERLAY_DIR:-$REPO_ROOT/build/de-g1-mvp/overlay}"
VENDORED_DIR="${DE_G1_VENDORED_DIR:-$SCRIPT_DIR/vendored-archives/linux}"
ALLOW_ONLINE=0
SKIP_DE0_G=0
DRY_RUN=0
VERBOSE=0

# When dot-sourced from a parent driver (build-mvp-iso.sh stage 4i),
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
    *) echo "[de-g1][error] unknown arg: $1" >&2; exit 1 ;;
  esac
done

log()  { echo "[de-g1] $*" >&2; }
vlog() { [ "$VERBOSE" = 1 ] && echo "[de-g1][verbose] $*" >&2 || true; }
die()  { echo "[de-g1][error] $*" >&2; exit "${2:-1}"; }

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

SENTINEL="$OVERLAY_DIR/var/lib/reproos-de-gnome-done"
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
           "$OVERLAY_DIR/etc/gdm3" \
           "$OVERLAY_DIR/etc/systemd/system/multi-user.target.wants" \
           "$OVERLAY_DIR/usr/local/bin" \
           "$OVERLAY_DIR/usr/local/sbin" \
           "$OVERLAY_DIR/var/lib" \
           "$OVERLAY_DIR/var/lib/gdm3"
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
    bash "$DE0_G_SH" "${DE0_G_ARGS[@]}" 2>&1 | sed 's/^/[de-g1]   /'
  else
    log "DE0-G base already applied (sentinel present): $DE0_G_SENTINEL"
  fi
fi

# ---------------------------------------------------------------------------
# Helpers (lifted from build-mvp-hyprland-rootfs.sh; identical shape).
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
# DE-G1 catalog set. ORDER MATTERS for registry.json byte-stability
# (sorted by name). DE0-G's six catalogs (mesa/libdrm/libwayland/
# libxkbcommon/fontconfig/dejavu-fonts) and DE-H1's 37 catalogs are
# excluded.
# ---------------------------------------------------------------------------

DE_G1_CATALOG_NAMES=(
  accountsservice
  adwaita-icon-theme
  dconf
  gdm
  gjs
  gnome-session
  gnome-settings-daemon
  gnome-shell
  gsettings-desktop-schemas
  libcanberra
  libgcr3
  libgjs
  libgnome-desktop
  libgraphene
  libgtk4
  libgudev
  libice
  libjson-glib
  libmozjs91
  libnss
  libpipewire
  libpolkit
  libsecret
  libsm
  libsoup2.4
  libstartup-notification
  libsystemd
  libwacom
  libxkbcommon-x11
  libxkbfile
  mutter
  xdg-desktop-portal-gnome
  xdg-desktop-portal-gtk
)

CATALOGS=()
for name in "${DE_G1_CATALOG_NAMES[@]}"; do
  p="$CATALOG_ROOT/$name.json"
  [ -f "$p" ] || die "catalog missing: $p" 2
  CATALOGS+=("$p")
done

log "processing ${#CATALOGS[@]} catalog(s) from $CATALOG_ROOT (overlay=$OVERLAY_DIR, dry-run=$DRY_RUN)"

LDCONF="$OVERLAY_DIR/etc/ld.so.conf.d/00-reproos-linux.conf"
# DE0-G + DE-H1 already initialized this file; we append. If both were
# skipped (--skip-de0-g and no DE-H1) and the file doesn't exist, create
# it now.
if [ "$DRY_RUN" = 0 ] && [ ! -f "$LDCONF" ]; then
  cat > "$LDCONF" <<'EOF'
# DE-G1: GNOME stack on top of DE0-G + (optionally) DE-H1.
EOF
fi

# Append a DE-G1 marker.
if [ "$DRY_RUN" = 0 ]; then
  echo "" >> "$LDCONF"
  echo "# DE-G1: GNOME 42 stack (gdm + gnome-shell + mutter + 30 support libs)." >> "$LDCONF"
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

    extract_tmp="$(mktemp -d -t "de-g1-extract-$cat_name-$deb_pkg.XXXXXX")"
    dpkg-deb -x "$deb_path" "$extract_tmp" || die "$cat_name/$deb_pkg: dpkg-deb -x failed" 1

    # Three catalogs need the FULL tree planted (not just expected_files):
    #   - gsettings-desktop-schemas : /usr/share/glib-2.0/schemas/*.xml
    #     (mutter + shell walk the dir at startup).
    #   - gnome-shell-common : /usr/share/gnome-shell/{js,modes,theme,...}
    #     (gnome-shell JS module loader walks the tree).
    #   - adwaita-icon-theme : /usr/share/icons/Adwaita/ (~13 MB; mutter
    #     + GTK4 walk the icon index).
    case "$cat_name" in
      gsettings-desktop-schemas|adwaita-icon-theme)
        if [ "$DRY_RUN" = 0 ]; then
          cp -a "$extract_tmp"/. "$store_dir/"
        fi
        ;;
      gnome-shell)
        # gnome-shell-common (the "all"-arch deb) ships /usr/share/gnome-shell;
        # the main gnome-shell deb ships /usr/share/applications + bin.
        # Full-extract the common deb only.
        if [ "$DRY_RUN" = 0 ] && [ "$deb_pkg" = "gnome-shell-common" ]; then
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
            # DE-H1 cascade B inherit: plant a /usr/local/bin/<name>
            # symlink so the autologin shell finds the binary on PATH.
            # gdm3 sbin -> /usr/local/sbin/; everything else under
            # usr/bin/ -> /usr/local/bin/. libexec binaries are
            # PATH-private by convention and NOT symlinked.
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
              # Remove the SONAME file if dpkg-deb -x already extracted
              # it (gsettings-desktop-schemas / adwaita full-copy case);
              # then replace with a relative symlink for relocatability.
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
  #   - usr/lib/x86_64-linux-gnu/      (canonical)
  #   - lib/x86_64-linux-gnu/          (libpcre3 / zlib1g legacy; not
  #                                     used by DE-G1 but kept for
  #                                     symmetry)
  #   - usr/lib/x86_64-linux-gnu/mutter-10/  (libmutter's sub-lib dir)
  if [ "$DRY_RUN" = 0 ]; then
    for libdir in "usr/lib/x86_64-linux-gnu" "lib/x86_64-linux-gnu" "usr/lib/x86_64-linux-gnu/mutter-10"; do
      if [ -d "$store_dir/$libdir" ]; then
        ldconf_line="/opt/reproos-linux/store/$cat_hash/$libdir"
        # Avoid duplicate lines if rerun without sentinel.
        grep -qxF "$ldconf_line" "$LDCONF" 2>/dev/null || echo "$ldconf_line" >> "$LDCONF"
      fi
    done
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
# DE-G1 GNOME-config layer.
#
# /etc/gdm3/custom.conf                       gdm3 autologin config.
# /etc/wayland-sessions/gnome.desktop         gdm session entry.
# /usr/local/bin/repro-start-gnome.sh         session entry shim.
# /etc/profile.d/gnome-gsettings.sh           XDG_DATA_DIRS export for
#                                             gsettings-desktop-schemas.
# /etc/systemd/system/multi-user.target.wants/gdm.service
#                                             symlink activating gdm.
# /var/lib/gdm3/                              empty stateful dir.
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = 0 ]; then
  # Resolve store hashes we need for the env exports + the gdm symlink.
  gdm_hash="$(catalog_hash gdm "$(jget "$CATALOG_ROOT/gdm.json" 'd["package"]["version"]')" "$(jget "$CATALOG_ROOT/gdm.json" 'd["package"]["snapshot"]')")"
  schemas_hash="$(catalog_hash gsettings-desktop-schemas "$(jget "$CATALOG_ROOT/gsettings-desktop-schemas.json" 'd["package"]["version"]')" "$(jget "$CATALOG_ROOT/gsettings-desktop-schemas.json" 'd["package"]["snapshot"]')")"
  adwaita_hash="$(catalog_hash adwaita-icon-theme "$(jget "$CATALOG_ROOT/adwaita-icon-theme.json" 'd["package"]["version"]')" "$(jget "$CATALOG_ROOT/adwaita-icon-theme.json" 'd["package"]["snapshot"]')")"

  log "planting /etc/gdm3/custom.conf"
  cat > "$OVERLAY_DIR/etc/gdm3/custom.conf" <<'EOF'
# DE-G1: GDM autologin configuration.
#
# Per repro-start-gnome.sh, the DE0-S `repro` user (uid=1000) is the
# autologin target. WaylandEnable=true forces the Wayland session path
# (mutter --wayland inside gnome-shell). InitialSetupEnable=false skips
# the first-boot wizard (gnome-initial-setup is NOT in the closure
# anyway; this is a defensive kill-switch).

[daemon]
WaylandEnable=true
AutomaticLoginEnable=true
AutomaticLogin=repro
InitialSetupEnable=false

[security]

[xdmcp]

[chooser]

[debug]
EOF

  log "planting /etc/wayland-sessions/gnome.desktop"
  cat > "$OVERLAY_DIR/etc/wayland-sessions/gnome.desktop" <<'EOF'
[Desktop Entry]
Name=GNOME
Comment=ReproOS GNOME Wayland session (DE-G1)
Exec=/usr/local/bin/repro-start-gnome.sh
TryExec=/usr/local/bin/gnome-shell
Type=Application
DesktopNames=GNOME
EOF

  log "planting /usr/local/bin/repro-start-gnome.sh"
  cat > "$OVERLAY_DIR/usr/local/bin/repro-start-gnome.sh" <<'EOF'
#!/usr/bin/env bash
# DE-G1 Wayland session entry shim.
#
# Sources DE0-S session env, honours REPRO_HEADLESS, execs gnome-session
# (which in turn execs gnome-shell + the gsd-* daemons via XDG-autostart).

set -e

# Source any /etc/profile.d/*.sh exports that the catalog tier needs
# (LD_LIBRARY_PATH, XDG_DATA_DIRS, __EGL_VENDOR_LIBRARY_DIRS,
# XKB_CONFIG_ROOT). Per DE0-S the user shell already does this for
# interactive logins; explicit re-source here covers greeter / gdm
# autologin non-interactive exec paths.
if [ -d /etc/profile.d ]; then
  for f in /etc/profile.d/*.sh; do
    [ -r "$f" ] && . "$f"
  done
fi

# XDG_RUNTIME_DIR comes from logind (DE0-S). Sanity-check.
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  echo "[repro-start-gnome] WARN: XDG_RUNTIME_DIR unset; logind may not be running" >&2
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"
fi

# Headless mode: MUTTER_DEBUG_DUMMY_MODE_SPECS bypasses the DRM
# backend and renders to a dummy in-memory output. Used by DE-G2's
# vm-harness boot test when the DRM backend doesn't behave on
# Hyper-V SyntheticVideo.
if [ "${REPRO_HEADLESS:-0}" = "1" ]; then
  export MUTTER_DEBUG_DUMMY_MODE_SPECS="1024x768@60"
  export MUTTER_DEBUG_FORCE_KMS_MODE=simple
  export WLR_LIBINPUT_NO_DEVICES=1
fi

# Cascade C lesson (DE-H1): start a session-bus dbus-daemon if one isn't
# already running. gnome-session activates dconf-service + the gsd-*
# daemons over the session bus.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  if command -v dbus-daemon >/dev/null 2>&1; then
    eval "$(dbus-daemon --session --fork --print-address=1 --print-pid=1 | awk 'NR==1{print "export DBUS_SESSION_BUS_ADDRESS="$0} NR==2{print "export DBUS_SESSION_BUS_PID="$0}')"
  fi
fi

# Dispatch to gnome-session (which execs gnome-shell). DE-G2 cascade B
# inheritance: hardcode /usr/local/bin/gnome-session so the shim does
# not depend on PATH being correctly set in the autologin shell.
if [ -x /usr/local/bin/gnome-session ]; then
  exec /usr/local/bin/gnome-session --session=gnome "$@"
elif command -v gnome-session >/dev/null 2>&1; then
  exec gnome-session --session=gnome "$@"
elif [ -x /usr/local/bin/gnome-shell ]; then
  # Fallback: run gnome-shell standalone (no gsd-* daemons; smoke only).
  exec /usr/local/bin/gnome-shell --wayland "$@"
else
  echo "[repro-start-gnome] FATAL: no gnome-session or gnome-shell on PATH" >&2
  exit 127
fi
EOF
  chmod +x "$OVERLAY_DIR/usr/local/bin/repro-start-gnome.sh"

  log "planting /etc/profile.d/gnome-gsettings.sh"
  cat > "$OVERLAY_DIR/etc/profile.d/gnome-gsettings.sh" <<EOF
# DE-G1: point XDG_DATA_DIRS at the overlay-planted GNOME data tiers so
# GLib's g_settings_new() finds the schemas and GtkIconTheme finds
# Adwaita. The values are colon-separated and prepend to any existing
# XDG_DATA_DIRS so distro-default paths still resolve when present.
__deg1_extra_data="/opt/reproos-linux/store/$schemas_hash/usr/share:/opt/reproos-linux/store/$adwaita_hash/usr/share"
export XDG_DATA_DIRS="\${__deg1_extra_data}\${XDG_DATA_DIRS:+:\$XDG_DATA_DIRS}"
unset __deg1_extra_data
EOF

  log "wiring gdm.service into multi-user.target.wants"
  # Symlink target lives inside the store (the catalog planted it).
  ln -sf "/opt/reproos-linux/store/$gdm_hash/lib/systemd/system/gdm.service" \
         "$OVERLAY_DIR/etc/systemd/system/multi-user.target.wants/gdm.service"

  # DE-H2 cascade E inheritance: refresh the LD_LIBRARY_PATH env-export
  # file with the union of DE0-G + DE-H1 + DE-G1 lib paths. The DE-H1
  # builder writes /etc/profile.d/reproos-libpath.sh; we OVERWRITE it
  # here from the current LDCONF state. (If DE-H1 wasn't applied, this
  # is the first writer; same outcome.)
  log "refreshing /etc/profile.d/reproos-libpath.sh (DE-H2 cascade E inherit)"
  LD_PATHS=""
  while IFS= read -r line; do
    case "$line" in
      ""|"#"*) continue ;;
    esac
    if [ -z "$LD_PATHS" ]; then
      LD_PATHS="$line"
    else
      LD_PATHS="$LD_PATHS:$line"
    fi
  done < "$LDCONF"
  cat > "$OVERLAY_DIR/etc/profile.d/reproos-libpath.sh" <<EOF
# DE-G1 + DE-H1 + DE0-G: LD_LIBRARY_PATH for the catalog-planted store
# libs.
#
# The R9 from-source base ships no ldconfig / ld.so.cache so the
# /etc/ld.so.conf.d/*.conf entries are NOT consumed by the linker at
# binary launch. Exporting LD_LIBRARY_PATH gives the same effect at
# the user-shell level (and the repro-start-{gnome,hyprland}.sh shims
# source this file before exec'ing the compositor).
#
# Order matches /etc/ld.so.conf.d/00-reproos-linux.conf.
export LD_LIBRARY_PATH="$LD_PATHS\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
EOF

  # DE-H2 cascade E inheritance: splice /etc/profile.d/*.sh sourcing
  # into /etc/profile if not already there. Idempotent via the marker.
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
  # DE-H1 writes "# DE-H1: source /etc/profile.d/*.sh"; we honour either
  # marker as already-done.
  if ! grep -qE "^# DE-(H1|G1): source /etc/profile.d/\*\.sh$" "$PROFILE_FILE"; then
    cat >> "$PROFILE_FILE" <<'EOF'

# DE-G1: source /etc/profile.d/*.sh
# (The R9 base /etc/profile follows the POSIX contract that does not
# automatically source /etc/profile.d/*.sh; add it explicitly so the
# autologin user shell picks up the catalog-store env exports,
# including LD_LIBRARY_PATH and XDG_DATA_DIRS.)
if [ -d /etc/profile.d ]; then
  for __f in /etc/profile.d/*.sh; do
    [ -r "$__f" ] && . "$__f"
  done
  unset __f
fi
EOF
  fi

  # Pre-create /var/lib/gdm3 with mode 0750 (the gdm user doesn't exist
  # at this stage — that's a DE-G2 boot-time concern via systemd-sysusers
  # — but the directory must exist so gdm.service starts).
  chmod 0750 "$OVERLAY_DIR/var/lib/gdm3" 2>/dev/null || true

  # Pin mtimes for determinism.
  find "$OVERLAY_DIR/opt/reproos-linux" \
       "$OVERLAY_DIR/etc/ld.so.conf.d" \
       "$OVERLAY_DIR/etc/gdm3" \
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
DE-G1 GNOME 42 stack applied.
Date: $(date -u +%Y-%m-%dT%H:%M:%SZ -d "@$SOURCE_DATE_EPOCH")
Overlay: $OVERLAY_DIR
Source: ubuntu-jammy (.deb harvest)

Planted catalogs ($PLANTED_COUNT):
$(python3 -c "
import json
reg = json.load(open('$REG_PATH'))
de_g1_names = {'accountsservice','adwaita-icon-theme','dconf','gdm','gjs',
               'gnome-session','gnome-settings-daemon','gnome-shell',
               'gsettings-desktop-schemas','libcanberra','libgcr3',
               'libgjs','libgnome-desktop','libgraphene','libgtk4',
               'libgudev','libice','libjson-glib','libmozjs91','libnss',
               'libpipewire','libpolkit','libsecret','libsm','libsoup2.4',
               'libstartup-notification','libsystemd','libwacom',
               'libxkbcommon-x11','libxkbfile','mutter',
               'xdg-desktop-portal-gnome','xdg-desktop-portal-gtk'}
for e in reg:
    if e['name'] in de_g1_names:
        print(f\"  - {e['name']:30} {e['version']:32}  hash={e['store_hash']}  files={e['file_count']}\")
")

Skipped catalogs ($SKIPPED_COUNT, advisory-only): none

Totals (DE-G1 layer only):
  .deb closure size: $TOTAL_BYTES bytes (~$((TOTAL_BYTES / 1024)) KB / $((TOTAL_BYTES / 1024 / 1024)) MB)
  planted files:     $TOTAL_FILES

Planted config:
  /etc/gdm3/custom.conf                                                (autologin gdm config)
  /etc/wayland-sessions/gnome.desktop                                  (gdm session entry)
  /usr/local/bin/repro-start-gnome.sh                                  (session entry shim)
  /etc/profile.d/gnome-gsettings.sh                                    (XDG_DATA_DIRS export)
  /etc/profile.d/reproos-libpath.sh                                    (LD_LIBRARY_PATH; refreshed)
  /etc/systemd/system/multi-user.target.wants/gdm.service              (gdm activation)
  /var/lib/gdm3/                                                       (gdm stateful dir)

Next step:
  DE-G2 : vm-harness Hyper-V GNOME boot test (boots ISO, autologin, exec
          repro-start-gnome.sh, assert gnome-shell up).
EOF

  touch -h --date="@$SOURCE_DATE_EPOCH" "$SENTINEL" 2>/dev/null || true
fi

log "DE-G1 overlay-plant DONE (planted=$PLANTED_COUNT skipped=$SKIPPED_COUNT files=$TOTAL_FILES bytes=$TOTAL_BYTES dry_run=$DRY_RUN)"
exit 0

#!/usr/bin/env bash
# build-linux-graphics-stack.sh -- DE0-G catalog -> overlay-plant driver.
#
# Reads recipes/catalog/linux/*.json (6 catalogs: mesa, libdrm,
# libwayland, libxkbcommon, fontconfig, dejavu-fonts) and for each:
#
#   1. Fetches each catalog.payload_files[].deb_url into
#      vendored-archives/linux/ (gitignored).
#   2. Verifies each .deb's sha256 + size matches the pin (fails closed
#      with exit 3 on mismatch).
#   3. Extracts each .deb under a per-catalog scratch dir via dpkg-deb -x.
#   4. Verifies each catalog.payload_files[].expected_files[] entry
#      lands under the extraction root (fails closed with exit 4).
#   5. Plants the verified subtree under
#      $OVERLAY/opt/reproos-linux/store/<catalog-hash>/ where
#      <catalog-hash> = sha256(catalog.package.name + version + snapshot)
#      truncated to 16 hex chars (deterministic per pin).
#   6. Creates SONAME symlinks for every shared_library entry.
#   7. Appends to $OVERLAY/etc/ld.so.conf.d/00-reproos-linux.conf so
#      Wayland compositors find the libs at runtime.
#   8. Maintains $OVERLAY/opt/reproos-linux/store/registry.json listing
#      each plant with name + version + store-hash + .deb shas +
#      file-count + advisory dependency closure.
#   9. Drops idempotent sentinel /var/lib/reproos-de0-graphics-done.
#
# Why /opt/reproos-linux/store/<hash>/ ?
#
#   Mirrors D3's /Applications/repro-store/<name>/ macOS convention
#   and W3's drive_c/repro-store/<name>/ Windows convention. Each
#   catalog entry gets its own content-addressed store dir; the
#   ld.so.conf.d wiring makes them visible without polluting
#   /usr/lib. A future cleanup pass (uninstall a catalog entry) just
#   removes the store dir + ld.so.conf.d snippet.
#
# Idempotency contract.
#
#   The sentinel /var/lib/reproos-de0-graphics-done short-circuits a
#   second invocation. To force re-apply (e.g. after editing a
#   catalog), delete the sentinel + the entire
#   /opt/reproos-linux/store/ tree.
#
# Honest scope.
#
#   This script does NOT run `ldconfig` (no build-host ldconfig
#   dependency; CI runs on hosts that may not have it). The SONAME
#   symlinks land manually; first boot's `ldconfig` (via systemd-tmpfiles
#   or sysvinit) sees them and populates the cache normally.
#
#   This script does NOT walk transitive dependencies. The
#   dependency_closure[] field on each catalog is advisory and recorded
#   into registry.json for downstream tooling; the build relies on the
#   jammy host already shipping libelf / zlib / libxcb-* / libffi8
#   (same precedent DE0-D uses for libsystemd / libexpat).
#
# Usage
# -----
#
#   build-linux-graphics-stack.sh
#     [--overlay-dir <path>]   # default: build/de0-g-mvp/overlay
#     [--catalog-root <path>]  # default: recipes/catalog/linux/
#     [--vendored <path>]      # default: vendored-archives/linux/
#     [--allow-online]         # permit curl fetch when .deb missing
#                              #   (defaults to offline-only — the
#                              #    caller pre-populates vendored/)
#     [--dry-run]              # parse + verify, but don't write the overlay
#     [--verbose]
#
# Exit codes:
#   0    success
#   1    argument / preflight error (missing dpkg-deb / curl / sha256sum)
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
OVERLAY_DIR="${DE0_G_OVERLAY_DIR:-$REPO_ROOT/build/de0-g-mvp/overlay}"
VENDORED_DIR="${DE0_G_VENDORED_DIR:-$SCRIPT_DIR/vendored-archives/linux}"
ALLOW_ONLINE=0
DRY_RUN=0
VERBOSE=0

# When dot-sourced from a parent driver (build-mvp-iso.sh stage 4g),
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
    --dry-run)        DRY_RUN=1;           shift ;;
    --verbose)        VERBOSE=1;           shift ;;
    -h|--help)
      sed -n '1,/^set -euo pipefail$/p' "$0" | sed -n '/^#/p' >&2
      exit 0 ;;
    *) echo "[de0-g][error] unknown arg: $1" >&2; exit 1 ;;
  esac
done

log()  { echo "[de0-g] $*" >&2; }
vlog() { [ "$VERBOSE" = 1 ] && echo "[de0-g][verbose] $*" >&2 || true; }
die()  { echo "[de0-g][error] $*" >&2; exit "${2:-1}"; }

[ -d "$CATALOG_ROOT" ] || die "catalog root missing: $CATALOG_ROOT" 1

# ---------------------------------------------------------------------------
# Preflight: required tools. python3 for JSON parsing (consistent with W3 +
# D3); curl for fetch; sha256sum + stat for verification; dpkg-deb for
# .deb extraction.
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

SENTINEL="$OVERLAY_DIR/var/lib/reproos-de0-graphics-done"
if [ "$DRY_RUN" = 0 ] && [ -f "$SENTINEL" ]; then
  log "sentinel present ($SENTINEL); skipping (idempotent no-op)"
  exit 0
fi

if [ "$DRY_RUN" = 0 ]; then
  mkdir -p "$OVERLAY_DIR" "$VENDORED_DIR" \
           "$OVERLAY_DIR/opt/reproos-linux/store" \
           "$OVERLAY_DIR/etc/ld.so.conf.d" \
           "$OVERLAY_DIR/var/lib"
fi

# ---------------------------------------------------------------------------
# Helper: extract a value from a JSON file using python3 (no jq dep,
# matches W3 / D3 conventions).
# ---------------------------------------------------------------------------

jget() {
  python3 - "$1" <<PYEOF
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print($2)
PYEOF
}

# Compute a deterministic 16-char store-hash from a catalog's pin
# tuple. Matches the spec's "store/<hash>/" layout. Pure SHA-256;
# no randomness, no SOURCE_DATE_EPOCH dependence.
catalog_hash() {
  local name="$1" version="$2" snapshot="$3"
  printf '%s|%s|%s' "$name" "$version" "$snapshot" | sha256sum | awk '{print substr($1,1,16)}'
}

# ---------------------------------------------------------------------------
# Enumerate catalogs. DE0-G uses an explicit allowlist (matches DE-H1
# pattern) so newer catalog tiers (DE-H1, DE-G1, DE-K1) dropping JSONs
# into recipes/catalog/linux/ don't get picked up by the DE0-G base
# pass. The order is name-sorted so registry.json is byte-stable.
# ---------------------------------------------------------------------------

DE0_G_CATALOG_NAMES=(
  dejavu-fonts
  fontconfig
  libdrm
  libwayland
  libxkbcommon
  mesa
)

CATALOGS=()
for name in "${DE0_G_CATALOG_NAMES[@]}"; do
  f="$CATALOG_ROOT/$name.json"
  [ -f "$f" ] || die "DE0-G catalog missing: $f" 2
  CATALOGS+=("$f")
done

[ "${#CATALOGS[@]}" -gt 0 ] || die "no catalogs in $CATALOG_ROOT" 2

log "processing ${#CATALOGS[@]} catalog(s) from $CATALOG_ROOT (overlay=$OVERLAY_DIR, dry-run=$DRY_RUN)"

# ---------------------------------------------------------------------------
# Pass 1: per-catalog fetch + verify + extract + plant.
#
# We accumulate registry entries in a python-readable temp file so the
# final registry.json can be emitted with sorted keys + sorted entries
# in a single python invocation.
# ---------------------------------------------------------------------------

REG_TMP="$(mktemp -t "de0g-registry.XXXXXX.json")"
trap 'rm -f "$REG_TMP"' EXIT
echo '[]' > "$REG_TMP"

LDCONF="$OVERLAY_DIR/etc/ld.so.conf.d/00-reproos-linux.conf"
if [ "$DRY_RUN" = 0 ]; then
  cat > "$LDCONF" <<'EOF'
# DE0-G: Wayland-prerequisite Linux graphics stack.
#
# Each catalog plants under /opt/reproos-linux/store/<hash>/ and
# exposes its libs via the line below. ld.so walks these in order;
# duplicates from /usr/lib win on first match, which is fine because
# /usr/lib's mesa/libdrm/etc are NOT shipped in the R9 base image (only
# their support libs are) so no collision.
EOF
fi

TOTAL_BYTES=0
TOTAL_FILES=0

for catalog in "${CATALOGS[@]}"; do
  cat_name="$(jget "$catalog" 'd["package"]["name"]')"
  cat_version="$(jget "$catalog" 'd["package"]["version"]')"
  cat_snapshot="$(jget "$catalog" 'd["package"]["snapshot"]')"
  cat_runtime="$(jget "$catalog" 'd["runtime"]')"
  cat_source="$(jget "$catalog" 'd["package_source"]')"
  cat_banner="$(jget "$catalog" 'd.get("linux_version_banner","")')"

  [ "$cat_runtime" = "linux" ] || die "catalog $cat_name: runtime != linux ($cat_runtime)" 2
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

  deb_shas=""
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

    deb_shas="$deb_shas $deb_pkg:$deb_sha"

    # Extract under a scratch dir; we'll copy only the expected_files[]
    # entries into the store. Everything else (docs, lintian overrides)
    # stays in the temp dir and gets cleaned at end of loop.
    extract_tmp="$(mktemp -d -t "de0g-extract-$cat_name-$deb_pkg.XXXXXX")"
    dpkg-deb -x "$deb_path" "$extract_tmp" || die "$cat_name/$deb_pkg: dpkg-deb -x failed" 1

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
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
        case "$ef_kind" in
          binary) chmod +x "$dst" ;;
          shared_library)
            chmod 0644 "$dst"
            if [ -n "$ef_soname" ]; then
              soname_dst="$store_dir/$ef_soname"
              mkdir -p "$(dirname "$soname_dst")"
              # Create soname-link as a relative symlink so the store
              # tree is relocatable (boot loader's initramfs unions
              # the overlay under /, which preserves relative paths
              # but breaks absolute ones).
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

  # ld.so.conf.d snippet line for this catalog.
  ldconf_line="/opt/reproos-linux/store/$cat_hash/usr/lib/x86_64-linux-gnu"
  if [ "$DRY_RUN" = 0 ]; then
    # Only append the lib dir if any shared_library was planted in it.
    if [ -d "$store_dir/usr/lib/x86_64-linux-gnu" ]; then
      echo "$ldconf_line" >> "$LDCONF"
    fi
  fi

  # Build dependency_closure JSON for registry.
  dep_count="$(jget "$catalog" 'len(d["dependency_closure"])')"

  # Append registry entry via python (sorted-key clean JSON).
  python3 - "$REG_TMP" "$catalog" "$cat_hash" "$file_count" <<'PYEOF'
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
reg.append(entry)
reg.sort(key=lambda x: x["name"])
with open(reg_path, "w") as f:
    json.dump(reg, f, indent=2, sort_keys=True)
    f.write("\n")
PYEOF

  log "  $cat_name: planted $file_count file(s) under $store_dir"
done

# ---------------------------------------------------------------------------
# Emit registry.json into the overlay (skipped on dry-run).
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = 0 ]; then
  cp "$REG_TMP" "$OVERLAY_DIR/opt/reproos-linux/store/registry.json"
  log "registry.json: $OVERLAY_DIR/opt/reproos-linux/store/registry.json"

  # Pin mtimes for determinism (matches DE0-D's pattern).
  find "$OVERLAY_DIR/opt/reproos-linux" "$OVERLAY_DIR/etc/ld.so.conf.d" \
       -exec touch -h --date="@$SOURCE_DATE_EPOCH" {} + 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Sentinel + summary.
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = 0 ]; then
  cat > "$SENTINEL" <<EOF
DE0-G Linux graphics catalog tier applied.
Date: $(date -u +%Y-%m-%dT%H:%M:%SZ -d "@$SOURCE_DATE_EPOCH")
Overlay: $OVERLAY_DIR
Source: ubuntu-jammy (.deb harvest)

Planted catalogs (${#CATALOGS[@]}):
$(python3 -c "import json; reg=json.load(open('$REG_TMP')); [print(f\"  - {e['name']:18} {e['version']:32}  hash={e['store_hash']}  files={e['file_count']}\") for e in reg]")

Totals:
  .deb closure size: $TOTAL_BYTES bytes (~$((TOTAL_BYTES / 1024)) KB)
  planted files:     $TOTAL_FILES

ld.so wiring:
  /etc/ld.so.conf.d/00-reproos-linux.conf entries:
$(awk '/^\/opt/{print "    " $0}' "$LDCONF" 2>/dev/null)

Next step:
  DE-H1 : Hyprland catalog tier (will reference these libs via
          /opt/reproos-linux/store/ + ld.so.conf.d).
EOF

  touch -h --date="@$SOURCE_DATE_EPOCH" "$SENTINEL" 2>/dev/null || true
fi

log "DE0-G overlay-plant DONE (catalogs=${#CATALOGS[@]} files=$TOTAL_FILES bytes=$TOTAL_BYTES dry_run=$DRY_RUN)"
exit 0

#!/usr/bin/env bash
# W3 P2: W3 catalog -> WINEPREFIX subtree + W2 launcher manifest converter.
#
# Reads recipes/catalog/windows/{gh,just,ninja}.json; for each tool:
#
#   1. Verifies the archive .zip sha256 matches the pin
#      (fetched on demand into vendored-archives/windows/ — gitignored).
#   2. Extracts the payload files listed in catalog.payload_files,
#      verifying each file's content sha256 matches its pin (the W2
#      review's "no system DLL fallback" risk #3 is enforced here:
#      any DLL listed in dependency_dll_closure[] gets the same
#      content-sha256 gate; missing DLLs fail closed).
#   3. Materialises a per-tool prefix at
#      $STORE_ROOT/prefixes-win/<name>/bin/<binary>.exe (plus any DLLs).
#   4. Copies that prefix into $WINEPREFIX/drive_c/repro-store/<name>/
#      so WINE resolves it as C:\repro-store\<name>\bin\<binary>.exe.
#   5. Emits a W2 launcher manifest at <store-root>/prefixes-win/
#      <name>/launcher.manifest with the runtime=wine + wine_*
#      directives consumed by apps/reprobuild-sandbox-launcher.
#   6. Emits a per-tool shim at $OVERLAY/usr/local/bin/wine-<name>
#      that exec()s reprobuild-sandbox-launcher --manifest=...
#
# Honest scope: this script stops at on-disk overlay assembly. The
# initramfs-pack step belongs to a higher tier (build-mvp-multi-iso.sh
# wires the apt/dnf/pacman overlay into the initramfs; the W3 overlay
# layers on top of that the same way).
#
# Per the W1 doc's known-limitation #6 follow-up, this script supports
# --trim-wine-prefix which deletes drive_c/windows/Installer/ (the
# 250 MB Mono+Gecko MSI cache) once wineboot is complete. The PoC tools
# don't need Mono or Gecko (mscoree/mshtml are disabled via
# WINEDLLOVERRIDES); trimming closes the 533 MB -> ~250 MB gap from
# the W1 P3 gate.
#
# Usage
# -----
#
#   build-windows-prefix.sh
#     [--catalog-dir <path>]      # default: recipes/catalog/windows/
#     [--wine-prefix <path>]      # default: /tmp/w3-test-prefix
#     [--store-root <path>]       # default: build/w3-mvp/store
#     [--overlay <path>]          # default: build/w3-mvp/overlay
#     [--vendored <path>]         # default: vendored-archives/windows/
#     [--launcher-bin <path>]     # default: apps/reprobuild-sandbox-launcher/reprobuild-sandbox-launcher
#     [--init-prefix]             # also run wine-prefix-init.sh first
#     [--trim-wine-prefix]        # delete drive_c/windows/Installer/ post-init
#     [--smoke-test]              # run wine-<tool> --version after build
#     [--allow-online]            # permit curl fetch when archive missing
#                                 #   (defaults to offline-only — the
#                                 #    caller pre-populates vendored/)
#     [--verbose]
#
# Exit codes:
#   0    success
#   1    argument / preflight error
#   2    catalog file missing / malformed
#   3    archive sha256 mismatch
#   4    payload sha256 mismatch
#   5    wineprefix unhealthy
#   6    smoke-test FAIL (banner did not match wine_version_banner)
#   7    overlay write failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CATALOG_DIR="$REPO_ROOT/recipes/catalog/windows"
WINE_PREFIX_DIR="${W3_WINE_PREFIX:-/tmp/w3-test-prefix}"
STORE_ROOT="${W3_STORE_ROOT:-$REPO_ROOT/build/w3-mvp/store}"
OVERLAY_DIR="${W3_OVERLAY_DIR:-$REPO_ROOT/build/w3-mvp/overlay}"
VENDORED_DIR="${W3_VENDORED_DIR:-$SCRIPT_DIR/vendored-archives/windows}"
LAUNCHER_BIN="${W3_LAUNCHER_BIN:-$REPO_ROOT/apps/reprobuild-sandbox-launcher/reprobuild-sandbox-launcher}"
INIT_PREFIX=0
TRIM_PREFIX=0
SMOKE_TEST=0
ALLOW_ONLINE=0
VERBOSE=0

# When this script is dot-sourced into build-mvp-multi-iso.sh in a
# future milestone, the parent has already set OVERLAY / STORE_ROOT;
# we honour the parent's vars without forcing flags.
[ -n "${MVP_OVERLAY_DIR:-}" ] && OVERLAY_DIR="$MVP_OVERLAY_DIR"
[ -n "${MVP_STORE_ROOT:-}" ]  && STORE_ROOT="$MVP_STORE_ROOT"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --catalog-dir)     CATALOG_DIR="$2";     shift 2 ;;
    --catalog-dir=*)   CATALOG_DIR="${1#--catalog-dir=}"; shift ;;
    --wine-prefix)     WINE_PREFIX_DIR="$2"; shift 2 ;;
    --wine-prefix=*)   WINE_PREFIX_DIR="${1#--wine-prefix=}"; shift ;;
    --store-root)      STORE_ROOT="$2";      shift 2 ;;
    --store-root=*)    STORE_ROOT="${1#--store-root=}"; shift ;;
    --overlay)         OVERLAY_DIR="$2";     shift 2 ;;
    --overlay=*)       OVERLAY_DIR="${1#--overlay=}"; shift ;;
    --vendored)        VENDORED_DIR="$2";    shift 2 ;;
    --vendored=*)      VENDORED_DIR="${1#--vendored=}"; shift ;;
    --launcher-bin)    LAUNCHER_BIN="$2";    shift 2 ;;
    --launcher-bin=*)  LAUNCHER_BIN="${1#--launcher-bin=}"; shift ;;
    --init-prefix)     INIT_PREFIX=1;        shift ;;
    --trim-wine-prefix) TRIM_PREFIX=1;       shift ;;
    --smoke-test)      SMOKE_TEST=1;         shift ;;
    --allow-online)    ALLOW_ONLINE=1;       shift ;;
    --verbose)         VERBOSE=1;            shift ;;
    -h|--help)
      sed -n '1,/^set -euo pipefail$/p' "$0" | sed -n '/^#/p' >&2
      exit 0 ;;
    *) echo "[w3][error] unknown arg: $1" >&2; exit 1 ;;
  esac
done

log()  { echo "[w3] $*" >&2; }
vlog() { [ "$VERBOSE" = 1 ] && echo "[w3][verbose] $*" >&2 || true; }
die()  { echo "[w3][error] $*" >&2; exit "${2:-1}"; }

[ -d "$CATALOG_DIR" ] || die "catalog dir missing: $CATALOG_DIR" 1

mkdir -p "$VENDORED_DIR" "$STORE_ROOT/prefixes-win" "$OVERLAY_DIR/usr/local/bin"

# Preflight: required tools.
for t in python3 unzip sha256sum; do
  command -v "$t" >/dev/null 2>&1 || die "preflight: '$t' missing on PATH" 1
done

# ---------------------------------------------------------------------------
# Stage 1: optional WINEPREFIX init
# ---------------------------------------------------------------------------

if [ "$INIT_PREFIX" = 1 ]; then
  log "stage 1: initialising WINEPREFIX at $WINE_PREFIX_DIR"
  bash "$SCRIPT_DIR/wine-prefix-init.sh" --prefix-dir "$WINE_PREFIX_DIR" \
    ${VERBOSE:+--verbose} >&2 || die "wine-prefix-init.sh failed" 5
fi

# Verify the prefix is sane.
if [ ! -d "$WINE_PREFIX_DIR/drive_c" ]; then
  die "WINEPREFIX has no drive_c/: $WINE_PREFIX_DIR (use --init-prefix)" 5
fi

if [ "$TRIM_PREFIX" = 1 ]; then
  INSTALLER_DIR="$WINE_PREFIX_DIR/drive_c/windows/Installer"
  if [ -d "$INSTALLER_DIR" ]; then
    size_before="$(du -sb "$INSTALLER_DIR" 2>/dev/null | awk '{print $1}')"
    log "trim: deleting drive_c/windows/Installer/ (size=$size_before bytes)"
    rm -rf "$INSTALLER_DIR"
    # Also drop wine-mono + wine-gecko payloads from System32 if cached;
    # these are inert for PoC tools (mscoree+mshtml are overridden).
    rm -f "$WINE_PREFIX_DIR"/drive_c/windows/mono/* 2>/dev/null || true
    rm -rf "$WINE_PREFIX_DIR"/drive_c/windows/mono 2>/dev/null || true
  fi
fi

# ---------------------------------------------------------------------------
# Helper: extract a value from a JSON file using python3 (no jq dep).
# ---------------------------------------------------------------------------

jget() {
  # jget <json-file> <python-expr referencing 'd' (the loaded dict)>
  python3 - "$1" <<PYEOF
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print($2)
PYEOF
}

# ---------------------------------------------------------------------------
# Stage 2: iterate catalogs; fetch + verify + extract + plant + manifest.
# ---------------------------------------------------------------------------

CATALOGS=()
for f in "$CATALOG_DIR"/*.json; do
  [ -f "$f" ] || continue
  CATALOGS+=("$f")
done
[ "${#CATALOGS[@]}" -gt 0 ] || die "no catalogs in $CATALOG_DIR" 2

log "stage 2: processing ${#CATALOGS[@]} catalog(s) from $CATALOG_DIR"

PROCESSED=0
SMOKE_PASS=0
SMOKE_FAIL=0
SMOKE_LOG="$STORE_ROOT/prefixes-win/_smoke.log"
: > "$SMOKE_LOG"

for catalog in "${CATALOGS[@]}"; do
  name="$(jget "$catalog" 'd["package"]["name"]')"
  version="$(jget "$catalog" 'd["package"]["version"]')"
  runtime="$(jget "$catalog" 'd["runtime"]')"
  exec_path="$(jget "$catalog" 'd["exec_path"]')"
  prefix_id="$(jget "$catalog" 'd["wine_prefix_id"]')"
  banner_prefix="$(jget "$catalog" 'd.get("wine_version_banner","")')"

  [ "$runtime" = "wine" ] || die "catalog $name: runtime != wine ($runtime)" 2
  [ "$prefix_id" = "shared" ] || die "catalog $name: wine_prefix_id != shared ($prefix_id) — only shared is wired" 2

  archive_url="$(jget "$catalog" 'd["provisioning_methods"][0]["url"]')"
  archive_sha="$(jget "$catalog" 'd["provisioning_methods"][0]["sha256"]')"
  archive_size="$(jget "$catalog" 'd["provisioning_methods"][0]["size_bytes"]')"

  archive_basename="$(basename "$archive_url")"
  archive_path="$VENDORED_DIR/$archive_basename"

  log "  $name $version: catalog OK; archive=$archive_basename ($archive_size bytes)"

  if [ ! -f "$archive_path" ]; then
    if [ "$ALLOW_ONLINE" = 1 ]; then
      log "  $name: fetching $archive_url"
      curl -fsSL -o "$archive_path.part" "$archive_url" || die "$name: curl failed" 1
      mv "$archive_path.part" "$archive_path"
    else
      die "$name: archive missing at $archive_path (use --allow-online or pre-populate)" 1
    fi
  fi

  # Verify archive sha256.
  got_sha="$(sha256sum "$archive_path" | awk '{print $1}')"
  if [ "$got_sha" != "$archive_sha" ]; then
    die "$name: archive sha256 mismatch (expected $archive_sha, got $got_sha)" 3
  fi
  # Verify archive size.
  got_size="$(stat -c '%s' "$archive_path")"
  if [ "$got_size" != "$archive_size" ]; then
    die "$name: archive size mismatch (expected $archive_size, got $got_size)" 3
  fi
  vlog "  $name: archive sha256 + size verified"

  # Stage-aware extraction. We extract into a per-tool prefix under
  # $STORE_ROOT/prefixes-win/<name>/, then verify each catalog-listed
  # payload file's content sha256 + copy it to its install_relpath.
  toolprefix="$STORE_ROOT/prefixes-win/$name"
  rm -rf "$toolprefix"
  mkdir -p "$toolprefix/bin"

  extract_tmp="$(mktemp -d -t "w3-extract-$name.XXXXXX")"
  trap 'rm -rf "$extract_tmp"' EXIT
  unzip -q "$archive_path" -d "$extract_tmp" || die "$name: unzip failed" 1

  # Walk payload_files; verify + place each.
  payload_count="$(jget "$catalog" 'len(d["payload_files"])')"
  vlog "  $name: payload_files entries = $payload_count"

  i=0
  while [ "$i" -lt "$payload_count" ]; do
    arch_rel="$(jget "$catalog" "d[\"payload_files\"][$i][\"archive_relpath\"]")"
    inst_rel="$(jget "$catalog" "d[\"payload_files\"][$i][\"install_relpath\"]")"
    file_sha="$(jget "$catalog" "d[\"payload_files\"][$i][\"sha256\"]")"
    file_kind="$(jget "$catalog" "d[\"payload_files\"][$i][\"kind\"]")"

    src="$extract_tmp/$arch_rel"
    [ -f "$src" ] || die "$name: payload missing in archive: $arch_rel" 4
    got_file_sha="$(sha256sum "$src" | awk '{print $1}')"
    if [ "$got_file_sha" != "$file_sha" ]; then
      die "$name: payload $arch_rel sha mismatch (exp $file_sha got $got_file_sha)" 4
    fi

    dst="$toolprefix/$inst_rel"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    # Mark .exe + .dll as executable so WINE can map them.
    if [ "$file_kind" = "exe" ] || [ "$file_kind" = "dll" ]; then
      chmod +x "$dst"
    fi
    vlog "  $name: payload[$i] $arch_rel -> $inst_rel sha=OK"
    i=$((i + 1))
  done

  # Walk dependency_dll_closure[] — enforces W2 review risk #3
  # (no system DLL fallback). For the PoC tools this list is empty.
  dll_count="$(jget "$catalog" 'len(d["dependency_dll_closure"])')"
  if [ "$dll_count" -gt 0 ]; then
    die "$name: dependency_dll_closure non-empty ($dll_count); harvest path not wired yet" 1
  fi

  rm -rf "$extract_tmp"
  trap - EXIT

  # Plant the per-tool subtree inside the WINEPREFIX under
  # drive_c/repro-store/<name>/ so WINE resolves it as
  # C:\repro-store\<name>\ — matches the catalog.exec_path field.
  store_subtree="$WINE_PREFIX_DIR/drive_c/repro-store/$name"
  mkdir -p "$(dirname "$store_subtree")"
  rm -rf "$store_subtree"
  cp -r "$toolprefix" "$store_subtree"
  vlog "  $name: planted at $store_subtree"

  # Sanity: the catalog's exec_path is drive_c-relative; verify the
  # corresponding file exists post-plant.
  planted_exe="$WINE_PREFIX_DIR/$exec_path"
  [ -f "$planted_exe" ] || die "$name: exec_path missing post-plant: $planted_exe" 5

  # Compute wine_exec for the manifest. WINE accepts both
  # forward-slash POSIX (relative to drive_c) and C:/ drive-letter
  # form. We use C:/ for clarity (per W2 launcher MANIFEST-FORMAT.md
  # example). exec_path strips the leading "drive_c/" to yield the
  # C: path.
  wine_exec_c="C:/${exec_path#drive_c/}"

  # Emit the W2 launcher manifest.
  manifest="$toolprefix/launcher.manifest"
  cat > "$manifest" <<EOF
# W3-generated launcher manifest for $name $version
# Source catalog: $catalog
# Runtime: wine (W2)

runtime=wine
wine_prefix=$WINE_PREFIX_DIR
wine_exec=$wine_exec_c
wine_bin=/usr/bin/wine

# Bind the WINEPREFIX into the namespace so the launcher's drive_c
# verification step + WINE's per-binary file resolution both find the
# planted exe. The launcher dedupes overlapping binds, so listing the
# prefix here is safe even when a parent driver later layers a more
# specific bind on top.
$WINE_PREFIX_DIR:$WINE_PREFIX_DIR:rbind

# wine + wineserver walk /proc to discover sibling processes.
proc
EOF
  vlog "  $name: wrote launcher manifest at $manifest"

  # Emit the per-tool shim into the overlay tree.
  shim="$OVERLAY_DIR/usr/local/bin/wine-$name"
  cat > "$shim" <<EOF
#!/bin/sh
# W3-generated shim for wine-$name (catalog $catalog, version $version).
# Delegates to reprobuild-sandbox-launcher with the W3 manifest. The
# launcher exports WINEPREFIX + WINEDEBUG + WINEDLLOVERRIDES and
# exec()s wine with wine_exec as argv[1], forwarding "\$@".
exec "$LAUNCHER_BIN" --manifest="$manifest" -- "\$@"
EOF
  chmod +x "$shim"
  vlog "  $name: emitted shim at $shim"

  PROCESSED=$((PROCESSED + 1))

  # Smoke-test (optional). Runs the shim directly to confirm
  # end-to-end (catalog -> prefix -> manifest -> launcher -> wine
  # -> exe) returns the expected banner.
  if [ "$SMOKE_TEST" = 1 ]; then
    if [ ! -x "$LAUNCHER_BIN" ]; then
      log "  $name: SMOKE-SKIP launcher not built at $LAUNCHER_BIN"
      echo "$name SMOKE-SKIP launcher-not-found" >> "$SMOKE_LOG"
      continue
    fi
    if ! command -v wine >/dev/null 2>&1; then
      log "  $name: SMOKE-SKIP wine not on PATH"
      echo "$name SMOKE-SKIP wine-missing" >> "$SMOKE_LOG"
      continue
    fi

    set +e
    smoke_out="$("$shim" --version 2>&1)"
    smoke_exit=$?
    set -e

    echo "=== $name SMOKE exit=$smoke_exit ===" >> "$SMOKE_LOG"
    echo "$smoke_out" >> "$SMOKE_LOG"

    if [ "$smoke_exit" -ne 0 ]; then
      log "  $name: SMOKE-FAIL exit=$smoke_exit"
      SMOKE_FAIL=$((SMOKE_FAIL + 1))
      continue
    fi
    if [ -n "$banner_prefix" ]; then
      if echo "$smoke_out" | grep -qF "$banner_prefix"; then
        log "  $name: SMOKE-PASS banner matched ('$banner_prefix')"
        SMOKE_PASS=$((SMOKE_PASS + 1))
      else
        log "  $name: SMOKE-FAIL banner mismatch (expected substring: $banner_prefix)"
        SMOKE_FAIL=$((SMOKE_FAIL + 1))
      fi
    else
      log "  $name: SMOKE-PASS (no banner_prefix; exit=0 sufficient)"
      SMOKE_PASS=$((SMOKE_PASS + 1))
    fi
  fi
done

log "processed $PROCESSED catalog(s)"
if [ "$SMOKE_TEST" = 1 ]; then
  log "smoke: PASS=$SMOKE_PASS FAIL=$SMOKE_FAIL (log: $SMOKE_LOG)"
  if [ "$SMOKE_FAIL" -gt 0 ]; then
    exit 6
  fi
fi

log "W3 overlay assembled:"
log "  prefixes:  $STORE_ROOT/prefixes-win/"
log "  shims:    $OVERLAY_DIR/usr/local/bin/wine-*"
log "  prefix:   $WINE_PREFIX_DIR/drive_c/repro-store/"
exit 0

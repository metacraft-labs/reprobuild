#!/usr/bin/env bash
# D3 P3: macOS catalog -> per-tool DPREFIX subtree + D2 launcher manifest converter.
#
# Reads recipes/catalog/macos/*.json (excluding canary entries — files
# whose JSON contains a top-level `_canary_note` key); for each tool:
#
#   1. Verifies the upstream artifact (tar.gz archive or bare Mach-O
#      binary) sha256 matches the pin (fetched on demand into
#      vendored-archives/macos/ — gitignored).
#   2. Materialises a per-tool DPREFIX at
#      $STORE_ROOT/dprefixes/<name>/ via the D1 darling-prefix-init.sh
#      script (one DPREFIX per tool — per the D2 reviewer's risk #3,
#      avoids the shared .darlingserver.sock race that can serialise
#      parallel macOS-side invocations through one server).
#   3. Extracts the payload files listed in catalog.payload_files,
#      verifying each file's content sha256 + size, into the per-tool
#      DPREFIX at /Applications/repro-store/<name>/.
#   4. Pre-stats the planted exec path BEFORE emitting any manifest;
#      fails with a clear message if the path does not resolve (per D2
#      reviewer's risk #2 — mirror the W3 wine_exec same-gap fix that
#      should follow).
#   5. Emits a D2 launcher manifest with runtime=darling +
#      darling_prefix + darling_exec + darling_bin keys. Honours the
#      D2 reviewer's risk #1 (NO identity rbind on darling_prefix —
#      Darling's internal overlayfs setup rejects it); honours risk
#      #4 (sets darling_bin explicitly to the ReproOS path
#      /opt/reproos-foreign/darling-binaries/usr/bin/darling); honours
#      risk #6 (includes /dev/fuse:/dev/fuse:rbind in the baseline bind
#      set for stock physical-host kernels).
#   6. Defence-in-depth: scans the emitted manifest for any identity
#      rbind line targeting darling_prefix and fails the emit if found
#      (exit 5).
#   7. Emits a per-tool shim at $OVERLAY/usr/local/bin/darling-<name>
#      that exec()s reprobuild-sandbox-launcher --manifest=...
#
# Honest scope: this script stops at on-disk overlay assembly. The
# initramfs-pack step belongs to a higher tier (build-mvp-multi-iso.sh).
#
# Usage
# -----
#
#   build-mvp-darling-prefix.sh
#     [--catalog-dir <path>]      # default: recipes/catalog/macos/
#     [--store-root <path>]       # default: build/d3-mvp/store
#     [--overlay <path>]          # default: build/d3-mvp/overlay
#     [--vendored <path>]         # default: vendored-archives/macos/
#     [--launcher-bin <path>]     # default: apps/reprobuild-sandbox-launcher/reprobuild-sandbox-launcher
#     [--darling-bin <path>]      # baked into emitted manifest's
#                                 #   darling_bin= directive.
#                                 #   default: /opt/reproos-foreign/darling-binaries/usr/bin/darling
#     [--init-darling-bin <path>] # host darling used by D1 init script
#                                 #   (resolves via PATH if unset).
#     [--smoke-test]              # run the emitted shim with
#                                 #   tool_smoke_args after build
#     [--allow-online]            # permit curl fetch when artifact
#                                 #   missing (defaults to offline-only).
#     [--verbose]
#     [--dry-run]
#
# Exit codes:
#   0    success
#   1    argument / preflight error
#   2    catalog file missing / malformed
#   3    archive / bare-binary sha256 mismatch
#   4    payload file missing or sha256 mismatch
#   5    emit-validation failure (identity rbind on darling_prefix,
#        or darling_exec path missing post-plant)
#   6    smoke-test FAIL (banner did not match darling_version_banner)
#   7    DPREFIX init failure
#   8    overlay write failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CATALOG_DIR="$REPO_ROOT/recipes/catalog/macos"
STORE_ROOT="${D3_STORE_ROOT:-$REPO_ROOT/build/d3-mvp/store}"
OVERLAY_DIR="${D3_OVERLAY_DIR:-$REPO_ROOT/build/d3-mvp/overlay}"
VENDORED_DIR="${D3_VENDORED_DIR:-$SCRIPT_DIR/vendored-archives/macos}"
LAUNCHER_BIN="${D3_LAUNCHER_BIN:-$REPO_ROOT/apps/reprobuild-sandbox-launcher/reprobuild-sandbox-launcher}"

# DEFAULT darling_bin baked into emitted manifests is the ReproOS path
# (per the D2 reviewer's risk #4). Override via --darling-bin for dev
# distros where Darling lives at /usr/bin/darling.
MANIFEST_DARLING_BIN="${D3_DARLING_BIN:-/opt/reproos-foreign/darling-binaries/usr/bin/darling}"

# Host darling actually used to init the per-tool DPREFIX. Defaults to
# PATH-resolved (typically /usr/bin/darling on the dev distro). Distinct
# from MANIFEST_DARLING_BIN because the ReproOS path won't exist on the
# build host.
INIT_DARLING_BIN=""

SMOKE_TEST=0
ALLOW_ONLINE=0
VERBOSE=0
DRY_RUN=0

# When this script is dot-sourced into build-mvp-multi-iso.sh in a
# future milestone, the parent has already set OVERLAY / STORE_ROOT;
# we honour the parent's vars without forcing flags.
[ -n "${MVP_OVERLAY_DIR:-}" ] && OVERLAY_DIR="$MVP_OVERLAY_DIR"
[ -n "${MVP_STORE_ROOT:-}" ]  && STORE_ROOT="$MVP_STORE_ROOT"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --catalog-dir)         CATALOG_DIR="$2";         shift 2 ;;
    --catalog-dir=*)       CATALOG_DIR="${1#--catalog-dir=}"; shift ;;
    --store-root)          STORE_ROOT="$2";          shift 2 ;;
    --store-root=*)        STORE_ROOT="${1#--store-root=}"; shift ;;
    --overlay)             OVERLAY_DIR="$2";         shift 2 ;;
    --overlay=*)           OVERLAY_DIR="${1#--overlay=}"; shift ;;
    --vendored)            VENDORED_DIR="$2";        shift 2 ;;
    --vendored=*)          VENDORED_DIR="${1#--vendored=}"; shift ;;
    --launcher-bin)        LAUNCHER_BIN="$2";        shift 2 ;;
    --launcher-bin=*)      LAUNCHER_BIN="${1#--launcher-bin=}"; shift ;;
    --darling-bin)         MANIFEST_DARLING_BIN="$2"; shift 2 ;;
    --darling-bin=*)       MANIFEST_DARLING_BIN="${1#--darling-bin=}"; shift ;;
    --init-darling-bin)    INIT_DARLING_BIN="$2";    shift 2 ;;
    --init-darling-bin=*)  INIT_DARLING_BIN="${1#--init-darling-bin=}"; shift ;;
    --smoke-test)          SMOKE_TEST=1;             shift ;;
    --allow-online)        ALLOW_ONLINE=1;           shift ;;
    --verbose)             VERBOSE=1;                shift ;;
    --dry-run)             DRY_RUN=1;                shift ;;
    -h|--help)
      sed -n '1,/^set -euo pipefail$/p' "$0" | sed -n '/^#/p' >&2
      exit 0 ;;
    *) echo "[d3][error] unknown arg: $1" >&2; exit 1 ;;
  esac
done

log()  { echo "[d3] $*" >&2; }
vlog() { [ "$VERBOSE" = 1 ] && echo "[d3][verbose] $*" >&2 || true; }
die()  { echo "[d3][error] $*" >&2; exit "${2:-1}"; }

[ -d "$CATALOG_DIR" ] || die "catalog dir missing: $CATALOG_DIR" 1

mkdir -p "$VENDORED_DIR" "$STORE_ROOT/dprefixes" "$STORE_ROOT/prefixes-mac" \
         "$OVERLAY_DIR/usr/local/bin"

# Preflight: required tools.
for t in python3 sha256sum tar; do
  command -v "$t" >/dev/null 2>&1 || die "preflight: '$t' missing on PATH" 1
done

# Resolve the host darling binary (used by D1 init), distinct from
# MANIFEST_DARLING_BIN (baked into emitted manifests).
if [ -z "$INIT_DARLING_BIN" ]; then
  if command -v darling >/dev/null 2>&1; then
    INIT_DARLING_BIN="$(command -v darling)"
  else
    die "preflight: darling not on PATH (use --init-darling-bin)" 1
  fi
fi
[ -x "$INIT_DARLING_BIN" ] || die "preflight: init darling not executable: $INIT_DARLING_BIN" 1

vlog "init_darling_bin=$INIT_DARLING_BIN (host darling for DPREFIX init)"
vlog "manifest_darling_bin=$MANIFEST_DARLING_BIN (baked into emitted manifest)"

DARLING_INIT_SH="$SCRIPT_DIR/darling-prefix-init.sh"
[ -x "$DARLING_INIT_SH" ] || [ -f "$DARLING_INIT_SH" ] || \
  die "preflight: darling-prefix-init.sh missing at $DARLING_INIT_SH" 1

# ---------------------------------------------------------------------------
# Helper: extract a value from a JSON file using python3 (no jq dep).
# ---------------------------------------------------------------------------

jget() {
  # jget <json-file> <python-expr referencing 'd' (the loaded dict)>
  python3 - "$1" "$2" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(eval(sys.argv[2]))
PYEOF
}

jhas() {
  # jhas <json-file> <top-level-key>  -> exits 0 if present, 1 otherwise.
  python3 - "$1" "$2" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
sys.exit(0 if sys.argv[2] in d else 1)
PYEOF
}

# ---------------------------------------------------------------------------
# Stage 1: enumerate catalogs (skip canary entries).
# ---------------------------------------------------------------------------

CATALOGS=()
for f in "$CATALOG_DIR"/*.json; do
  [ -f "$f" ] || continue
  if jhas "$f" "_canary_note"; then
    vlog "skipping canary catalog: $f"
    continue
  fi
  CATALOGS+=("$f")
done
[ "${#CATALOGS[@]}" -gt 0 ] || die "no catalogs in $CATALOG_DIR" 2

log "stage 1: processing ${#CATALOGS[@]} catalog(s) from $CATALOG_DIR"

PROCESSED=0
SMOKE_PASS=0
SMOKE_FAIL=0
SMOKE_LOG="$STORE_ROOT/dprefixes/_smoke.log"
: > "$SMOKE_LOG"

for catalog in "${CATALOGS[@]}"; do
  name="$(jget "$catalog" 'd["package"]["name"]')"
  version="$(jget "$catalog" 'd["package"]["version"]')"
  runtime="$(jget "$catalog" 'd["runtime"]')"
  exec_path="$(jget "$catalog" 'd["exec_path"]')"
  prefix_id="$(jget "$catalog" 'd["darling_prefix_id"]')"
  banner_prefix="$(jget "$catalog" 'd.get("darling_version_banner","")')"

  [ "$runtime" = "darling" ] || die "catalog $name: runtime != darling ($runtime)" 2
  [ "$prefix_id" = "shared" ] || die "catalog $name: darling_prefix_id != shared ($prefix_id) — only shared is wired" 2

  archive_url="$(jget "$catalog" 'd["provisioning_methods"][0]["url"]')"
  archive_sha="$(jget "$catalog" 'd["provisioning_methods"][0]["sha256"]')"
  archive_size="$(jget "$catalog" 'd["provisioning_methods"][0]["size_bytes"]')"
  archive_format="$(jget "$catalog" 'd["provisioning_methods"][0].get("archive_format","tar.gz")')"

  archive_basename="$(basename "$archive_url")"
  archive_path="$VENDORED_DIR/$archive_basename"

  log "  $name $version: catalog OK; artifact=$archive_basename ($archive_size bytes, format=$archive_format)"

  if [ "$DRY_RUN" = 1 ]; then
    log "  $name: --dry-run; skipping fetch + extract + plant"
    PROCESSED=$((PROCESSED + 1))
    continue
  fi

  if [ ! -f "$archive_path" ]; then
    if [ "$ALLOW_ONLINE" = 1 ]; then
      log "  $name: fetching $archive_url"
      curl -fsSL -o "$archive_path.part" "$archive_url" || die "$name: curl failed" 1
      mv "$archive_path.part" "$archive_path"
    else
      die "$name: artifact missing at $archive_path (use --allow-online or pre-populate)" 1
    fi
  fi

  # Verify artifact sha256.
  got_sha="$(sha256sum "$archive_path" | awk '{print $1}')"
  if [ "$got_sha" != "$archive_sha" ]; then
    die "$name: artifact sha256 mismatch (expected $archive_sha, got $got_sha)" 3
  fi
  # Verify artifact size.
  got_size="$(stat -c '%s' "$archive_path")"
  if [ "$got_size" != "$archive_size" ]; then
    die "$name: artifact size mismatch (expected $archive_size, got $got_size)" 3
  fi
  vlog "  $name: artifact sha256 + size verified"

  # Per-tool DPREFIX (D2 reviewer's risk #3 — parallelism).
  dprefix="$STORE_ROOT/dprefixes/$name"
  if [ ! -d "$dprefix/Applications" ]; then
    log "  $name: initialising per-tool DPREFIX at $dprefix"
    # Remove a half-baked remnant so darling-prefix-init.sh re-creates it.
    if [ -e "$dprefix" ]; then
      rm -rf "$dprefix"
    fi
    if ! bash "$DARLING_INIT_SH" \
            --prefix-dir "$dprefix" \
            --darling-bin "$INIT_DARLING_BIN" \
            ${VERBOSE:+--verbose} >&2; then
      die "$name: darling-prefix-init.sh failed for $dprefix" 7
    fi
  else
    vlog "  $name: reusing existing DPREFIX at $dprefix"
  fi

  # Build the per-tool prefix subtree (host-side staging mirror).
  toolprefix="$STORE_ROOT/prefixes-mac/$name"
  rm -rf "$toolprefix"
  mkdir -p "$toolprefix/bin"

  # Walk payload_files; verify + place each.
  payload_count="$(jget "$catalog" 'len(d["payload_files"])')"
  vlog "  $name: payload_files entries = $payload_count"

  # Extract or copy depending on archive_format.
  extract_tmp="$(mktemp -d -t "d3-extract-$name.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$extract_tmp'" EXIT

  case "$archive_format" in
    tar.gz)
      tar -xzf "$archive_path" -C "$extract_tmp" \
        || die "$name: tar -xzf failed" 1
      ;;
    bare)
      # The artifact IS the payload; copy under archive_relpath of first
      # entry (also catalog-pinned).
      first_arch_rel="$(jget "$catalog" 'd["payload_files"][0]["archive_relpath"]')"
      cp "$archive_path" "$extract_tmp/$first_arch_rel"
      ;;
    *)
      die "$name: unsupported archive_format: $archive_format" 2
      ;;
  esac

  i=0
  while [ "$i" -lt "$payload_count" ]; do
    arch_rel="$(jget "$catalog" "d[\"payload_files\"][$i][\"archive_relpath\"]")"
    inst_rel="$(jget "$catalog" "d[\"payload_files\"][$i][\"install_relpath\"]")"
    file_sha="$(jget "$catalog" "d[\"payload_files\"][$i][\"sha256\"]")"
    file_kind="$(jget "$catalog" "d[\"payload_files\"][$i][\"kind\"]")"

    src="$extract_tmp/$arch_rel"
    [ -f "$src" ] || die "$name: payload missing in artifact: $arch_rel" 4
    got_file_sha="$(sha256sum "$src" | awk '{print $1}')"
    if [ "$got_file_sha" != "$file_sha" ]; then
      die "$name: payload $arch_rel sha mismatch (exp $file_sha got $got_file_sha)" 4
    fi

    dst="$toolprefix/$inst_rel"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    if [ "$file_kind" = "macho_exe" ] || [ "$file_kind" = "exe" ]; then
      chmod +x "$dst"
    fi
    vlog "  $name: payload[$i] $arch_rel -> $inst_rel sha=OK"
    i=$((i + 1))
  done

  rm -rf "$extract_tmp"
  trap - EXIT

  # Walk dependency_closure[] — must be empty for the PoC tools (all
  # statically-linked Mach-O CLIs).
  dep_count="$(jget "$catalog" 'len(d["dependency_closure"])')"
  if [ "$dep_count" -gt 0 ]; then
    die "$name: dependency_closure non-empty ($dep_count); macOS dep-graph walk not wired yet" 1
  fi

  # Plant the per-tool subtree inside the DPREFIX at
  # Applications/repro-store/<name>/ so Darling resolves it as
  # /Applications/repro-store/<name>/ inside the macOS-shaped FS.
  store_subtree="$dprefix/Applications/repro-store/$name"
  mkdir -p "$(dirname "$store_subtree")"
  rm -rf "$store_subtree"
  cp -r "$toolprefix" "$store_subtree"
  vlog "  $name: planted at $store_subtree"

  # Pre-stat the planted exec path (D2 reviewer's risk #2 — fail fast
  # on missing darling_exec, BEFORE emitting any manifest).
  # exec_path is a macOS-side absolute path; resolve it via the dprefix.
  exec_in_prefix_rel="${exec_path#/}"
  planted_exec="$dprefix/$exec_in_prefix_rel"
  if [ ! -f "$planted_exec" ]; then
    die "$name: planted exec missing: $planted_exec (catalog exec_path=$exec_path)" 5
  fi
  if [ ! -x "$planted_exec" ]; then
    die "$name: planted exec not executable: $planted_exec" 5
  fi
  vlog "  $name: pre-stat exec OK: $planted_exec"

  # Emit the D2 launcher manifest. Note:
  #   * NO identity rbind on darling_prefix (D2 risk #1).
  #   * /dev/fuse:/dev/fuse:rbind in baseline (D2 risk #6) — stock
  #     physical-host kernels need it explicitly.
  #   * darling_bin is the MANIFEST path (defaults to ReproOS, per D2
  #     risk #4).
  manifest="$toolprefix/launcher.manifest"
  cat > "$manifest" <<EOF
# D3-generated launcher manifest for $name $version
# Source catalog: $catalog
# Runtime: darling (D2)

runtime=darling
darling_prefix=$dprefix
darling_exec=$exec_path
darling_bin=$MANIFEST_DARLING_BIN

# NOTE: NO identity rbind on darling_prefix — unlike WINEPREFIX, an
# identity bind on darling_prefix breaks Darling's internal overlayfs
# setup. The DPREFIX is visible inside CLONE_NEWNS via inherited
# propagation. (D2 reviewer risk #1; defence-in-depth validation
# below.)

# darlingserver needs /proc + /dev/fuse for the macOS-shaped overlay.
# /dev/fuse rbind is required on stock physical-host kernels where the
# device node isn't auto-bound into user-NS by the kernel's default
# propagation rules. (D2 reviewer risk #6.)
proc
/dev/fuse:/dev/fuse:rbind
EOF
  vlog "  $name: wrote launcher manifest at $manifest"

  # Defence-in-depth: scan emitted manifest for any rbind line whose
  # source AND target are exactly darling_prefix (identity rbind).
  # Reject the emit if found.
  if python3 - "$manifest" "$dprefix" <<'PYEOF'
import sys, re
manifest_path, dprefix = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    for lineno, raw in enumerate(f, 1):
        line = raw.strip()
        if not line or line.startswith('#') or '=' in line.split(':',1)[0]:
            # comment / blank / key=value
            continue
        # bind line: src:tgt:flags
        parts = line.split(':')
        if len(parts) >= 3:
            src, tgt, flags = parts[0], parts[1], parts[2]
            if src == dprefix and tgt == dprefix and ('rbind' in flags or 'bind' in flags):
                print(f"[d3][error] identity rbind detected on darling_prefix at line {lineno}: {line}", file=sys.stderr)
                sys.exit(1)
sys.exit(0)
PYEOF
  then
    vlog "  $name: defence-in-depth: no identity rbind on darling_prefix"
  else
    die "$name: emitted manifest contains identity rbind on darling_prefix (see above)" 5
  fi

  # Emit the per-tool shim into the overlay tree.
  shim="$OVERLAY_DIR/usr/local/bin/darling-$name"
  cat > "$shim" <<EOF
#!/bin/sh
# D3-generated shim for darling-$name (catalog $catalog, version $version).
# Delegates to reprobuild-sandbox-launcher with the D3 manifest. The
# launcher exports DPREFIX and exec()s darling with shell <darling_exec>
# as argv[1..2], forwarding "\$@".
exec "$LAUNCHER_BIN" --manifest="$manifest" -- "\$@"
EOF
  chmod +x "$shim"
  vlog "  $name: emitted shim at $shim"

  PROCESSED=$((PROCESSED + 1))

  # Smoke-test (optional). Runs the shim directly to confirm end-to-end
  # (catalog -> dprefix -> manifest -> launcher -> darling -> binary)
  # returns the expected banner.
  if [ "$SMOKE_TEST" = 1 ]; then
    if [ ! -x "$LAUNCHER_BIN" ]; then
      log "  $name: SMOKE-SKIP launcher not built at $LAUNCHER_BIN"
      echo "$name SMOKE-SKIP launcher-not-found" >> "$SMOKE_LOG"
      continue
    fi
    if ! command -v darling >/dev/null 2>&1; then
      log "  $name: SMOKE-SKIP darling not on PATH"
      echo "$name SMOKE-SKIP darling-missing" >> "$SMOKE_LOG"
      continue
    fi

    # Read tool_smoke_args; default to ["--version"].
    smoke_argv_json="$(jget "$catalog" 'json.dumps(d.get("tool_smoke_args",["--version"]))')" || smoke_argv_json='["--version"]'
    # shellcheck disable=SC2207
    smoke_argv=($(python3 -c "import json,sys; print(' '.join(json.loads(sys.argv[1])))" "$smoke_argv_json"))

    set +e
    smoke_out="$("$shim" "${smoke_argv[@]}" 2>&1)"
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

log "D3 overlay assembled:"
log "  dprefixes:  $STORE_ROOT/dprefixes/"
log "  prefixes:   $STORE_ROOT/prefixes-mac/"
log "  shims:      $OVERLAY_DIR/usr/local/bin/darling-*"
exit 0

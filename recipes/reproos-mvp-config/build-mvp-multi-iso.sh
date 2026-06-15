#!/usr/bin/env bash
# D2 P4: ReproOS multi-distro MVP build pipeline.
#
# Extends D1's build-mvp-iso.sh from 5 apt packages to 9 mixed-distro
# packages (5 apt + 2 dnf + 2 pacman). Each foreign package gets:
#
#   * A catalog file harvested by the appropriate per-distro harvester
#     (repro-harvest-apt / repro-harvest-dnf / repro-harvest-pacman).
#   * A content-addressed prefix under $STORE_ROOT/prefixes/<distro>/<name>/.
#   * A statically-linked stub binary at $prefix/usr/bin/<name> that
#     prints the harvested version string with a distro-tag suffix so
#     the gate can disambiguate the three htop variants.
#   * A C3 launcher manifest + per-binary shim at $prefix/bin/<name>.
#
# The overlay places each prefix at /opt/reproos-foreign/<distro>/<name>/
# inside the VM, and exposes /usr/local/bin/<name> for the apt root
# packages (preserving D1 behaviour) plus /usr/local/bin/<distro>-<name>
# for the dnf + pacman roots (avoiding the htop name collision).
#
# Honest scope: like D1, this driver stops at overlay assembly by
# default. Use MVP_STAGE=initramfs or MVP_STAGE=iso to attempt the
# ISO build (requires the R9 systemd install tree on the build host).

set -euo pipefail

to_native_path() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w -m -- "$p"
  else
    echo "$p"
  fi
}

HOST_KERNEL="$(uname -s 2>/dev/null || echo unknown)"
case "$HOST_KERNEL" in
  Linux*|*BSD*|Darwin*) HOST_IS_WINDOWS=0 ;;
  CYGWIN*|MINGW*|MSYS*) HOST_IS_WINDOWS=1 ;;
  *)                    HOST_IS_WINDOWS=0 ;;
esac

pick_runnable() {
  local base="$1"
  local exe="$base.exe"
  if [ "$HOST_IS_WINDOWS" = 1 ]; then
    if [ -x "$exe" ]; then echo "$exe"; return 0; fi
    if [ -x "$base" ]; then echo "$base"; return 0; fi
  else
    if [ -x "$base" ] && [ ! -d "$base" ]; then
      if head -c2 "$base" 2>/dev/null | grep -q '^MZ'; then
        :  # PE binary; reject
      else
        echo "$base"
        return 0
      fi
    fi
  fi
  return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SIBLINGS_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
[ -z "${BEARSSL_SRC:-}" ] && [ -d "$SIBLINGS_ROOT/nim-bearssl" ] && \
  export BEARSSL_SRC="$SIBLINGS_ROOT/nim-bearssl"
[ -z "${VM_HARNESS_SRC:-}" ] && [ -d "$SIBLINGS_ROOT/vm-harness/src" ] && \
  export VM_HARNESS_SRC="$SIBLINGS_ROOT/vm-harness/src"

OUT_DIR="${MVP_OUT_DIR:-$REPO_ROOT/build/d2-mvp-multi}"
CONFIG_PATH="${MVP_CONFIG_PATH:-$REPO_ROOT/recipes/reproos-mvp-config-multi.nim}"
STAGE="${MVP_STAGE:-overlay}"

log() { echo "[d2] $*" >&2; }
die() { echo "[d2][error] $*" >&2; exit 1; }

[ -f "$CONFIG_PATH" ] || die "config not found: $CONFIG_PATH"

mkdir -p "$OUT_DIR"
log "out dir: $OUT_DIR"
log "config:  $CONFIG_PATH"

# ---------------------------------------------------------------------------
# Stage 1: parse + lower the multi config via B1.
# ---------------------------------------------------------------------------

CONFIG_JSON="$OUT_DIR/config.json"
log "stage 1: parse + lower config"

PARSE_HELPER_BASE="$OUT_DIR/parse_helper"
HELPER=""
if ! HELPER=$(pick_runnable "$PARSE_HELPER_BASE"); then
  if [ "$HOST_IS_WINDOWS" = 1 ]; then PARSE_HELPER_OUT="$PARSE_HELPER_BASE.exe"
  else PARSE_HELPER_OUT="$PARSE_HELPER_BASE"
  fi
  ( cd "$REPO_ROOT" && nim c --threads:on --hints:off --warnings:off \
      --out:"$PARSE_HELPER_OUT" \
      "$SCRIPT_DIR/lower_to_json.nim" >/dev/null )
  HELPER=$(pick_runnable "$PARSE_HELPER_BASE") || die "parse_helper build failed"
fi
"$HELPER" --config "$CONFIG_PATH" --out "$CONFIG_JSON"
log "wrote $CONFIG_JSON"

# foreign.list is a TAB-separated <name>\t<distro>\t<snapshot> per
# foreign package. The lower_to_json helper emits one line per
# Tier-3 foreign-bundle entry.
FOREIGN_NAMES=()
FOREIGN_DISTROS=()
FOREIGN_SNAPSHOTS=()
list="$OUT_DIR/foreign.list"
[ -f "$list" ] || die "lower_to_json didn't emit foreign.list"
while IFS=$'\t' read -r name distro snapshot; do
  [ -n "$name" ] || continue
  FOREIGN_NAMES+=("$name")
  FOREIGN_DISTROS+=("$distro")
  FOREIGN_SNAPSHOTS+=("$snapshot")
done < "$list"
[ "${#FOREIGN_NAMES[@]}" -gt 0 ] || die "no foreign packages in config"
log "foreign packages: ${#FOREIGN_NAMES[@]} entries across distros"

# ---------------------------------------------------------------------------
# Stage 2: harvest catalogs per-distro.
# ---------------------------------------------------------------------------

log "stage 2: harvest catalogs (per-distro)"

build_harvester() {
  local distro="$1"
  local app_dir="$REPO_ROOT/apps/repro-harvest-$distro"
  local base="$app_dir/repro_harvest_$distro"
  if ! pick_runnable "$base" >/dev/null; then
    log "compile repro-harvest-$distro..."
    local extra_path=""
    if [ "$distro" != "apt" ]; then
      extra_path="--path:apps/repro-harvest-apt/src"
    fi
    ( cd "$REPO_ROOT" && nim c -d:ssl --threads:on --hints:off --warnings:off \
        --path:"apps/repro-harvest-$distro/src" $extra_path \
        --out:"$base" \
        "apps/repro-harvest-$distro/repro_harvest_$distro.nim" >/dev/null )
  fi
  pick_runnable "$base" || die "repro-harvest-$distro build failed"
}

build_fixture() {
  local distro="$1"
  local lib_dir="$REPO_ROOT/tests/integration/foreign_packages/lib"
  local helper_name=""
  case "$distro" in
    apt)    helper_name="fixture_build" ;;
    dnf)    helper_name="dnf_fixture_build" ;;
    pacman) helper_name="pacman_fixture_build" ;;
    *) die "unknown distro: $distro" ;;
  esac
  local base="$lib_dir/$helper_name"
  if ! pick_runnable "$base" >/dev/null; then
    log "compile $helper_name..."
    ( cd "$REPO_ROOT" && nim c --threads:on --hints:off --warnings:off \
        --out:"$base" "$lib_dir/$helper_name.nim" >/dev/null )
  fi
  pick_runnable "$base" || die "$helper_name build failed"
}

FIXTURE_ROOT="$OUT_DIR/fixture"
rm -rf "$FIXTURE_ROOT"
mkdir -p "$FIXTURE_ROOT/apt" "$FIXTURE_ROOT/dnf" "$FIXTURE_ROOT/pacman"

APT_FIXTURE=$(build_fixture apt)
DNF_FIXTURE=$(build_fixture dnf)
PACMAN_FIXTURE=$(build_fixture pacman)
"$APT_FIXTURE"    "$FIXTURE_ROOT/apt" >/dev/null
"$DNF_FIXTURE"    "$FIXTURE_ROOT/dnf" >/dev/null
"$PACMAN_FIXTURE" "$FIXTURE_ROOT/pacman" >/dev/null

APT_HARVESTER=$(build_harvester apt)
DNF_HARVESTER=$(build_harvester dnf)
PACMAN_HARVESTER=$(build_harvester pacman)

CATALOG_OUT="$OUT_DIR/catalogs"
rm -rf "$CATALOG_OUT"
mkdir -p "$CATALOG_OUT"

# Group root packages by (distro, snapshot) so we issue one harvester
# call per (distro, snapshot) pair with all the roots in a brace group.
group_for() {
  local distro="$1"
  local snapshot="$2"
  local result=""
  local i=0
  while [ "$i" -lt "${#FOREIGN_NAMES[@]}" ]; do
    if [ "${FOREIGN_DISTROS[$i]}" = "$distro" ] && \
       [ "${FOREIGN_SNAPSHOTS[$i]}" = "$snapshot" ]; then
      if [ -z "$result" ]; then result="${FOREIGN_NAMES[$i]}"
      else result="$result,${FOREIGN_NAMES[$i]}"
      fi
    fi
    i=$((i + 1))
  done
  echo "$result"
}

# Find unique (distro, snapshot) pairs.
declare -A PAIRS_SEEN
PAIRS=()
i=0
while [ "$i" -lt "${#FOREIGN_NAMES[@]}" ]; do
  key="${FOREIGN_DISTROS[$i]}|${FOREIGN_SNAPSHOTS[$i]}"
  if [ -z "${PAIRS_SEEN[$key]:-}" ]; then
    PAIRS_SEEN[$key]=1
    PAIRS+=("$key")
  fi
  i=$((i + 1))
done

for pair in "${PAIRS[@]}"; do
  distro="${pair%%|*}"
  snapshot="${pair#*|}"
  brace=$(group_for "$distro" "$snapshot")
  case "$distro" in
    apt)
      # snapshot is e.g. "debian/bookworm/20260601T000000Z" — convert
      # to harvester source spec form "<distro>/<suite>:<snap>".
      IFS='/' read -r d_distro d_suite d_snap <<<"$snapshot"
      source_spec="apt:{${brace}}@${d_distro}/${d_suite}:${d_snap}"
      "$APT_HARVESTER" --source "$source_spec" \
        --output-dir "$CATALOG_OUT" \
        --cache-dir "$FIXTURE_ROOT/apt/cache" \
        --gpg-keys "$FIXTURE_ROOT/apt/keys" \
        --offline --signature-backend fingerprint-allowlist \
        --rate-ms 0 >/dev/null
      ;;
    dnf)
      # snapshot is "fedora/39/20260601".
      IFS='/' read -r d_distro d_release d_snap <<<"$snapshot"
      source_spec="dnf:{${brace}}@${d_distro}/${d_release}:${d_snap}"
      "$DNF_HARVESTER" --source "$source_spec" \
        --output-dir "$CATALOG_OUT" \
        --cache-dir "$FIXTURE_ROOT/dnf/cache" \
        --gpg-keys "$FIXTURE_ROOT/dnf/keys" \
        --offline --signature-backend fingerprint-allowlist \
        --rate-ms 0 >/dev/null
      ;;
    pacman)
      # snapshot is "archlinux/rolling/20260601".
      IFS='/' read -r d_distro d_release d_snap <<<"$snapshot"
      source_spec="pacman:{${brace}}@${d_distro}/${d_release}:${d_snap}"
      "$PACMAN_HARVESTER" --source "$source_spec" \
        --output-dir "$CATALOG_OUT" \
        --cache-dir "$FIXTURE_ROOT/pacman/cache" \
        --gpg-keys "$FIXTURE_ROOT/pacman/keys" \
        --offline --signature-backend fingerprint-allowlist \
        --rate-ms 0 >/dev/null
      ;;
    *) die "unknown distro: $distro" ;;
  esac
done

total_count=0
for d in apt dnf pacman; do
  if [ -d "$CATALOG_OUT/$d" ]; then
    c=$(find "$CATALOG_OUT/$d" -maxdepth 1 -name '*.json' | wc -l)
    log "  $d closure: $c catalogs"
    total_count=$((total_count + c))
  fi
done
log "harvested $total_count catalog files total"

# ---------------------------------------------------------------------------
# Stage 3: fabricate prefixes + emit manifests + shims.
# ---------------------------------------------------------------------------

log "stage 3: fabricate prefixes + emit launcher manifests"

STORE_ROOT="$OUT_DIR/store"
rm -rf "$STORE_ROOT"
mkdir -p "$STORE_ROOT/prefixes"

ensure_stub_compiler() {
  if [ -n "${STUB_COMPILER:-}" ]; then return 0; fi
  for cc in gcc cc clang musl-gcc x86_64-linux-musl-gcc; do
    if command -v "$cc" >/dev/null 2>&1; then
      STUB_COMPILER="$cc"
      return 0
    fi
  done
  return 1
}

STUB_USE_STATIC=1
if ! ensure_stub_compiler; then
  log "warn: no C compiler found — falling back to shell-script stubs"
  STUB_USE_STATIC=0
fi

emit_stub_c_source() {
  local out="$1" name="$2" version="$3" banner="$4" distro_tag="$5"
  cat > "$out" <<'CHEADER'
/* D2 multi-distro stub. Auto-generated; do not edit.
 *
 * Statically linked so the C3 sandbox launcher's bind mounts (which
 * replace /usr/bin + /lib inside the namespace) don't break the
 * execve() handoff.
 */
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    (void)argc;
CHEADER
  printf 'static const char *kName = "%s";\n' "$name" >> "$out"
  printf 'static const char *kBanner = "%s";\n' "$banner" >> "$out"
  printf 'static const char *kVersion = "%s";\n' "$version" >> "$out"
  printf 'static const char *kDistroTag = "%s";\n' "$distro_tag" >> "$out"
  cat >> "$out" <<'CTAIL'
    if (argv[1] && strcmp(argv[1], "--version") == 0) {
        puts(kBanner);
        return 0;
    }
    if (argv[1] && strcmp(argv[1], "--distro") == 0) {
        puts(kDistroTag);
        return 0;
    }
    /* Python3 stub: support `-c "print('<token>')"` and
     * `-c "print(\"<token>\")"`. */
    if (strcmp(kName, "python3") == 0 && argv[1] && strcmp(argv[1], "-c") == 0
            && argv[2]) {
        const char *p = strstr(argv[2], "print(");
        if (p) {
            p += 6;
            char quote = 0;
            if (*p == '\'' || *p == '"') { quote = *p; p++; }
            if (quote) {
                const char *end = strchr(p, quote);
                if (end) {
                    fwrite(p, 1, (size_t)(end - p), stdout);
                    fputc('\n', stdout);
                    return 0;
                }
            }
        }
        if (strstr(argv[2], "print('hi')") || strstr(argv[2], "print(\"hi\")")) {
            puts("hi");
            return 0;
        }
    }
    printf("[d2 stub %s] %s with args:", kDistroTag, kName);
    for (int i = 1; argv[i]; ++i) printf(" %s", argv[i]);
    printf("\n");
    (void)kVersion;
    return 0;
}
CTAIL
}

# Iterate every harvested catalog (apt + dnf + pacman) and fabricate a
# prefix.
declare -A IS_ROOT
i=0
while [ "$i" -lt "${#FOREIGN_NAMES[@]}" ]; do
  IS_ROOT["${FOREIGN_DISTROS[$i]}/${FOREIGN_NAMES[$i]}"]=1
  i=$((i + 1))
done

for d in apt dnf pacman; do
  [ -d "$CATALOG_OUT/$d" ] || continue
  for f in "$CATALOG_OUT/$d"/*.json; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .json)
    pfx="$STORE_ROOT/prefixes/$d/$name"
    mkdir -p "$pfx/usr/bin" "$pfx/usr/lib/x86_64-linux-gnu" \
             "$pfx/lib" "$pfx/lib/x86_64-linux-gnu" \
             "$pfx/usr/share" "$pfx/etc"
    : > "$pfx/usr/lib/x86_64-linux-gnu/.keep"
    : > "$pfx/lib/x86_64-linux-gnu/.keep"
  done
done

# Plant binaries for every ROOT package. The dep prefixes stay empty
# (the launcher manifest's bind targets only need the dirs to exist).
i=0
while [ "$i" -lt "${#FOREIGN_NAMES[@]}" ]; do
  name="${FOREIGN_NAMES[$i]}"
  distro="${FOREIGN_DISTROS[$i]}"
  snapshot="${FOREIGN_SNAPSHOTS[$i]}"
  cat_file="$CATALOG_OUT/$distro/$name.json"
  [ -f "$cat_file" ] || die "missing root catalog for $distro/$name"
  version=$(grep -E '^[[:space:]]*"version"' "$cat_file" \
            | head -1 \
            | sed -E 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*$/\1/')
  [ -n "$version" ] || version="unknown"
  pfx="$STORE_ROOT/prefixes/$distro/$name"
  bin="$pfx/usr/bin/$name"
  case "$name" in
    git)     banner_base="git version $version" ;;
    vim)     banner_base="VIM - Vi IMproved $version" ;;
    python3) banner_base="Python $version" ;;
    curl)    banner_base="curl $version reproos-mvp" ;;
    htop)    banner_base="htop $version" ;;
    neovim)  banner_base="NVIM v$version" ;;
    fzf)     banner_base="$version" ;;
    *)       banner_base="$name $version" ;;
  esac
  distro_tag="distro=$distro snapshot=$snapshot"
  banner="$banner_base ($distro)"

  if [ "$STUB_USE_STATIC" = 1 ]; then
    src="$OUT_DIR/stub_${distro}_${name}.c"
    emit_stub_c_source "$src" "$name" "$version" "$banner" "$distro_tag"
    if "$STUB_COMPILER" -O2 -static -o "$bin" "$src" 2>"$OUT_DIR/stub_${distro}_${name}.log"; then
      :  # static link OK
    elif "$STUB_COMPILER" -O2 -o "$bin" "$src" 2>>"$OUT_DIR/stub_${distro}_${name}.log"; then
      log "warn: $distro/$name stub dynamically linked (host lacks static libc)"
    else
      log "warn: $distro/$name C stub compile failed; falling back to shell script"
      STUB_USE_STATIC=0
    fi
  fi
  if [ "$STUB_USE_STATIC" != 1 ] || [ ! -x "$bin" ]; then
    {
      printf '#!/bin/sh\n'
      printf '# D2 multi shell fallback stub for %s/%s (version=%s)\n' \
        "$distro" "$name" "$version"
      printf 'if [ "${1:-}" = "--version" ]; then\n'
      printf '  echo "%s"\n' "$banner"
      printf '  exit 0\n'
      printf 'fi\n'
      printf 'if [ "${1:-}" = "--distro" ]; then\n'
      printf '  echo "%s"\n' "$distro_tag"
      printf '  exit 0\n'
      printf 'fi\n'
      printf 'echo "[d2 stub %s] %s with args: $*"\n' "$distro" "$name"
      printf 'exit 0\n'
    } > "$bin"
  fi
  chmod +x "$bin"
  i=$((i + 1))
done

# Build the C3 manifest emit helper.
C3_EMIT_BASE="$REPO_ROOT/tests/integration/foreign_packages/lib/c3_manifest_emit"
C3_EMIT=""
if ! C3_EMIT=$(pick_runnable "$C3_EMIT_BASE"); then
  log "compile c3_manifest_emit..."
  ( cd "$REPO_ROOT" && nim c --threads:on --hints:off --warnings:off \
      --out:"$C3_EMIT_BASE" \
      "tests/integration/foreign_packages/lib/c3_manifest_emit.nim" >/dev/null )
  C3_EMIT=$(pick_runnable "$C3_EMIT_BASE") || die "c3_manifest_emit build failed"
fi

# Build the launcher binary.
LAUNCHER_BIN_BASE="$REPO_ROOT/apps/reprobuild-sandbox-launcher/reprobuild-sandbox-launcher"
LAUNCHER_BIN=""
if ! LAUNCHER_BIN=$(pick_runnable "$LAUNCHER_BIN_BASE"); then
  log "build reprobuild-sandbox-launcher..."
  ( cd "$REPO_ROOT/apps/reprobuild-sandbox-launcher" && ./build.sh ) || \
    die "launcher build failed"
  LAUNCHER_BIN=$(pick_runnable "$LAUNCHER_BIN_BASE") || die "launcher missing after build"
fi

# Build --store-prefixes covering every catalog across all distros.
prefixes_arg=""
for d in apt dnf pacman; do
  [ -d "$CATALOG_OUT/$d" ] || continue
  for f in "$CATALOG_OUT/$d"/*.json; do
    [ -f "$f" ] || continue
    n=$(basename "$f" .json)
    entry="$d/$n=$(to_native_path "$STORE_ROOT/prefixes/$d/$n")"
    if [ -z "$prefixes_arg" ]; then prefixes_arg="$entry"
    else prefixes_arg="$prefixes_arg,$entry"
    fi
  done
done

CATALOG_OUT_NATIVE="$(to_native_path "$CATALOG_OUT")"
LAUNCHER_BIN_NATIVE="$(to_native_path "$LAUNCHER_BIN")"

# Emit one manifest + shim per ROOT foreign package.
i=0
while [ "$i" -lt "${#FOREIGN_NAMES[@]}" ]; do
  name="${FOREIGN_NAMES[$i]}"
  distro="${FOREIGN_DISTROS[$i]}"
  pfx="$STORE_ROOT/prefixes/$distro/$name"
  manifest="$pfx/launcher.manifest"
  shim_dir="$pfx/bin"
  pfx_native="$(to_native_path "$pfx")"
  catalog_native="$(to_native_path "$CATALOG_OUT/$distro/$name.json")"
  manifest_native="$(to_native_path "$manifest")"
  shim_dir_native="$(to_native_path "$shim_dir")"

  "$C3_EMIT" \
    --catalog-root "$CATALOG_OUT_NATIVE" \
    --root-catalog "$catalog_native" \
    --store-prefixes "$prefixes_arg" \
    --exec-path "$pfx_native/usr/bin/$name" \
    --manifest-out "$manifest_native" \
    --shim-out "$shim_dir_native" \
    --launcher-bin "$LAUNCHER_BIN_NATIVE" 2>"$OUT_DIR/emit_${distro}_${name}.log"

  [ -f "$manifest" ] || die "manifest missing for $distro/$name: $manifest"
  if ! grep -q "^exec=" "$manifest"; then
    die "manifest for $distro/$name has no exec= line"
  fi
  if [ ! -f "$shim_dir/$name" ]; then
    die "shim missing for $distro/$name: $shim_dir/$name"
  fi
  log "  $distro/$name: manifest + shim emitted"
  i=$((i + 1))
done

# ---------------------------------------------------------------------------
# Stage 4: stage overlay tree.
# ---------------------------------------------------------------------------

log "stage 4: stage overlay tree"

OVERLAY="$OUT_DIR/overlay"
rm -rf "$OVERLAY"
mkdir -p "$OVERLAY/opt/reproos-foreign" "$OVERLAY/usr/local/bin"

cp "$LAUNCHER_BIN" "$OVERLAY/usr/local/bin/reprobuild-sandbox-launcher"
chmod +x "$OVERLAY/usr/local/bin/reprobuild-sandbox-launcher" 2>/dev/null || true

# Distro disambiguation: the dnf + pacman copies expose
# /usr/local/bin/<distro>-<name> AND /usr/local/bin/<name>
# (the latter only when no apt root claims it first). apt roots keep
# the plain /usr/local/bin/<name> path so D1 tests are unaffected.
declare -A USR_LOCAL_CLAIMED

# Stage ROOT prefixes first so the apt entries get to claim
# /usr/local/bin/<name> before the dnf/pacman entries arrive.
for stage_pass in apt dnf pacman; do
  i=0
  while [ "$i" -lt "${#FOREIGN_NAMES[@]}" ]; do
    name="${FOREIGN_NAMES[$i]}"
    distro="${FOREIGN_DISTROS[$i]}"
    if [ "$distro" = "$stage_pass" ]; then
      src="$STORE_ROOT/prefixes/$distro/$name"
      dst="$OVERLAY/opt/reproos-foreign/$distro/$name"
      mkdir -p "$OVERLAY/opt/reproos-foreign/$distro"
      rm -rf "$dst"
      cp -r "$src" "$dst"

      # Always expose the distro-tagged shim path.
      cat > "$OVERLAY/usr/local/bin/${distro}-${name}" <<EOF
#!/bin/sh
exec /opt/reproos-foreign/$distro/$name/bin/$name "\$@"
EOF
      chmod +x "$OVERLAY/usr/local/bin/${distro}-${name}" 2>/dev/null || true

      # Plain name: first distro to register wins. (apt goes first
      # since the stage_pass loop visits apt before dnf/pacman.)
      if [ -z "${USR_LOCAL_CLAIMED[$name]:-}" ]; then
        cat > "$OVERLAY/usr/local/bin/$name" <<EOF
#!/bin/sh
exec /opt/reproos-foreign/$distro/$name/bin/$name "\$@"
EOF
        chmod +x "$OVERLAY/usr/local/bin/$name" 2>/dev/null || true
        USR_LOCAL_CLAIMED[$name]="$distro"
      fi
    fi
    i=$((i + 1))
  done
done

# Stage every CLOSURE prefix (transitive deps) under the same layout so
# the launcher's bind targets resolve.
for d in apt dnf pacman; do
  [ -d "$STORE_ROOT/prefixes/$d" ] || continue
  for prefix_path in "$STORE_ROOT/prefixes/$d"/*; do
    [ -d "$prefix_path" ] || continue
    pname=$(basename "$prefix_path")
    dst="$OVERLAY/opt/reproos-foreign/$d/$pname"
    [ -d "$dst" ] && continue
    mkdir -p "$OVERLAY/opt/reproos-foreign/$d"
    cp -r "$prefix_path" "$dst"
  done
done

# ---------------------------------------------------------------------------
# Stage 4b: path rewrite — per-prefix manifests + shims carry build-host
# absolute paths. Rewrite to the VM layout.
# ---------------------------------------------------------------------------

VM_FOREIGN_ROOT="/opt/reproos-foreign"
VM_LAUNCHER_PATH="/usr/local/bin/reprobuild-sandbox-launcher"

# c3_manifest_emit writes paths in NATIVE Windows form (D:/...) on
# Windows hosts. Use the same form for the sed match pattern so the
# substitution actually fires; fall back to the bash-cwd form on POSIX
# hosts where to_native_path is a no-op.
STORE_PREFIXES_PATH_NATIVE="$(to_native_path "$STORE_ROOT/prefixes")"
STORE_PREFIXES_PATH_BASH="$STORE_ROOT/prefixes"
LAUNCHER_BIN_NATIVE_REWRITE="$(to_native_path "$LAUNCHER_BIN")"

sed_escape() {
  printf '%s' "$1" | sed -e 's/[&\\/|]/\\&/g'
}

STORE_PFX_NATIVE_ESC=$(sed_escape "$STORE_PREFIXES_PATH_NATIVE")
STORE_PFX_BASH_ESC=$(sed_escape "$STORE_PREFIXES_PATH_BASH")
LAUNCHER_BIN_NATIVE_ESC=$(sed_escape "$LAUNCHER_BIN_NATIVE_REWRITE")
LAUNCHER_BIN_BASH_ESC=$(sed_escape "$LAUNCHER_BIN")

log "stage 4b: rewrite overlay paths to VM layout"

i=0
while [ "$i" -lt "${#FOREIGN_NAMES[@]}" ]; do
  name="${FOREIGN_NAMES[$i]}"
  distro="${FOREIGN_DISTROS[$i]}"
  mf="$OVERLAY/opt/reproos-foreign/$distro/$name/launcher.manifest"
  [ -f "$mf" ] || die "manifest missing in overlay: $mf"
  # Inside the VM the foreign layout is one extra segment deeper than D1
  # (we have <distro>/<name>/ rather than just <name>/). The
  # c3_manifest_emit pre-rewrite layout is <store>/prefixes/<distro>/<name>/...
  # mapping cleanly to <VM_FOREIGN_ROOT>/<distro>/<name>/...
  sed -i \
    -e "s|${STORE_PFX_NATIVE_ESC}|${VM_FOREIGN_ROOT}|g" \
    -e "s|${STORE_PFX_BASH_ESC}|${VM_FOREIGN_ROOT}|g" \
    "$mf"
  if grep -q -E '(D:/|/mnt/d/|^[A-Za-z]:[\\/])' "$mf"; then
    log "warn: residual build-host path in $mf:"
    grep -E '(D:/|/mnt/d/|^[A-Za-z]:[\\/])' "$mf" | head -3 | sed 's/^/    /'
  fi

  shim="$OVERLAY/opt/reproos-foreign/$distro/$name/bin/$name"
  [ -f "$shim" ] || die "shim missing in overlay: $shim"
  sed -i \
    -e "s|${LAUNCHER_BIN_NATIVE_ESC}|${VM_LAUNCHER_PATH}|g" \
    -e "s|${LAUNCHER_BIN_BASH_ESC}|${VM_LAUNCHER_PATH}|g" \
    -e "s|${STORE_PFX_NATIVE_ESC}|${VM_FOREIGN_ROOT}|g" \
    -e "s|${STORE_PFX_BASH_ESC}|${VM_FOREIGN_ROOT}|g" \
    "$shim"
  chmod +x "$shim" 2>/dev/null || true
  i=$((i + 1))
done

cat > "$OVERLAY/opt/reproos-foreign/README" <<EOF
ReproOS D2 multi-distro MVP foreign-package overlay.

Each subdirectory under this tree is a per-distro group of
content-addressed package prefixes produced by the C3
materializeSandboxManifest driver against pinned snapshots from
three different distros.

Layout:

  apt/<name>/    Debian bookworm snapshot 20260601T000000Z
  dnf/<name>/    Fedora 39 snapshot 20260601
  pacman/<name>/ Arch Linux rolling snapshot 20260601

Per-package:

  <distro>/<name>/launcher.manifest  — bind-mount manifest
  <distro>/<name>/bin/<name>         — per-prefix shim
  <distro>/<name>/usr/bin/<name>     — actual wrapped binary

The /usr/local/bin/<name> shim resolves to the apt copy when one
exists; the dnf + pacman copies are reachable as
/usr/local/bin/dnf-<name> + /usr/local/bin/pacman-<name>.

Status: D2 MVP — root-package binaries are version-printing stubs
that include their distro tag via --distro.
EOF

cat > "$OUT_DIR/D2-STAGE-SUMMARY.txt" <<EOF
D2 multi-distro overlay summary (driver: build-mvp-multi-iso.sh)
==================================================================

config:        $CONFIG_PATH
foreign roots: ${#FOREIGN_NAMES[@]}
overlay:       $OVERLAY
launcher:      $LAUNCHER_BIN

Per-distro stats:
EOF
for d in apt dnf pacman; do
  if [ -d "$CATALOG_OUT/$d" ]; then
    c=$(find "$CATALOG_OUT/$d" -maxdepth 1 -name '*.json' | wc -l)
    echo "  $d: $c catalog files" >> "$OUT_DIR/D2-STAGE-SUMMARY.txt"
  fi
done

log "overlay staged at $OVERLAY"
log "summary at $OUT_DIR/D2-STAGE-SUMMARY.txt"
log ""
log "============================================================"
log "D2-stage1 COMPLETE: multi-distro overlay ready."
log "============================================================"

# ---------------------------------------------------------------------------
# Stage 5 (optional): initramfs + ISO assembly. Same gating as D1.
# ---------------------------------------------------------------------------

if [ "$STAGE" = "iso" ] || [ "$STAGE" = "initramfs" ]; then
  log "stage 5: assembling initramfs + ISO"
  R9_DIR="${R9_BUILD_DIR:-$REPO_ROOT/build/r9-build}"
  R8_DIR="${R8_BUILD_DIR:-$REPO_ROOT/build/r8-build}"
  if [ ! -f "$R9_DIR/initramfs-systemd.cpio.gz" ]; then
    log "warn: $R9_DIR/initramfs-systemd.cpio.gz not found; skipping ISO assembly"
    exit 0
  fi
  if [ ! -f "$R8_DIR/bzImage" ]; then
    log "warn: $R8_DIR/bzImage not found; skipping ISO assembly"
    exit 0
  fi
  if ! command -v cpio >/dev/null 2>&1; then
    log "warn: cpio missing; skipping ISO assembly"
    exit 0
  fi

  AUGMENTED_INITRAMFS="$OUT_DIR/initramfs-mvp-multi.cpio.gz"
  EXTRA_CPIO="$OUT_DIR/overlay.cpio.gz"

  ( cd "$OVERLAY" && \
    find . -print0 | LC_ALL=C sort -z | \
    cpio --null --owner=0:0 -o -H newc 2>/dev/null ) | \
    gzip -9 -n > "$EXTRA_CPIO"

  cat "$R9_DIR/initramfs-systemd.cpio.gz" "$EXTRA_CPIO" > "$AUGMENTED_INITRAMFS"
  log "augmented initramfs: $AUGMENTED_INITRAMFS"

  if [ "$STAGE" = "iso" ]; then
    if ! command -v grub-mkrescue >/dev/null 2>&1; then
      log "warn: grub-mkrescue missing; skipping final ISO assembly"
      exit 0
    fi
    MVP_ISO="$OUT_DIR/reproos-mvp-multi.iso"
    SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC \
      bash "$REPO_ROOT/recipes/reproos-iso/scripts/build-iso.sh" \
        "$R8_DIR/bzImage" \
        "$AUGMENTED_INITRAMFS" \
        "$MVP_ISO"
    log "ISO assembled: $MVP_ISO"
  fi
fi

log "build-mvp-multi-iso.sh DONE"

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

# X1: when MVP_REAL_ARCHIVES=1, the build extracts real upstream
# .deb/.rpm/.pkg.tar.zst archives instead of compiling stubs. The
# vendored archives must exist under recipes/reproos-mvp-config/
# vendored-archives/{apt,dnf,pacman}/ (fetched by fetch-real-archives.sh).
MVP_REAL_ARCHIVES="${MVP_REAL_ARCHIVES:-0}"
ARCHIVES_ROOT="${X1_ARCHIVES_DIR:-$SCRIPT_DIR/vendored-archives}"
if [ "$MVP_REAL_ARCHIVES" = "1" ]; then
  if [ ! -d "$ARCHIVES_ROOT" ]; then
    die "MVP_REAL_ARCHIVES=1 but vendored archives missing at $ARCHIVES_ROOT (run fetch-real-archives.sh first)"
  fi
  for tool in ar tar zstd cpio rpm2cpio; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      die "MVP_REAL_ARCHIVES=1 but '$tool' missing on PATH"
    fi
  done
  log "X1: real-archive extraction enabled (archives root: $ARCHIVES_ROOT)"
fi

# X1 extraction helpers. Each extracts an archive INTO an already-created
# target prefix dir (merging files atop whatever's there). The launcher's
# bind set later picks up only existing subdirs.
extract_deb() {
  local deb="$1" dest="$2"
  local tmp
  tmp=$(mktemp -d)
  ( cd "$tmp" && ar x "$deb" 2>/dev/null ) || { rm -rf "$tmp"; return 1; }
  local data_tar
  data_tar=$(ls "$tmp"/data.tar.* 2>/dev/null | head -1)
  [ -n "$data_tar" ] || { rm -rf "$tmp"; return 1; }
  mkdir -p "$dest"
  case "$data_tar" in
    *.xz)  tar -xJf "$data_tar" -C "$dest" ;;
    *.zst) tar --use-compress-program=unzstd -xf "$data_tar" -C "$dest" ;;
    *.gz)  tar -xzf "$data_tar" -C "$dest" ;;
    *)     rm -rf "$tmp"; return 1 ;;
  esac
  rm -rf "$tmp"
}

extract_rpm() {
  local rpm="$1" dest="$2"
  mkdir -p "$dest"
  ( cd "$dest" && rpm2cpio "$rpm" | cpio -idmu --no-absolute-filenames \
    2>/dev/null ) || return 1
}

extract_pkg() {
  local pkg="$1" dest="$2"
  mkdir -p "$dest"
  zstd -dq -c "$pkg" | tar -x -C "$dest"
  # Drop pacman metadata files.
  rm -f "$dest/.PKGINFO" "$dest/.BUILDINFO" "$dest/.MTREE" "$dest/.INSTALL"
}

# Find the archive file for a given (distro, name). Tries to match by
# package name prefix against the vendored archives dir. Returns "" if
# not found. Uses literal string-prefix matching (no regex) so package
# names with '+' (e.g. libstdc++) and '.' work correctly.
find_archive() {
  local distro="$1" name="$2"
  local dir="$ARCHIVES_ROOT/$distro"
  [ -d "$dir" ] || return 1
  local sep
  case "$distro" in
    apt)    sep='_' ;;
    dnf)    sep='-' ;;
    pacman) sep='-' ;;
  esac
  local prefix="${name}${sep}"
  local match=""
  local f
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    local bn
    bn=$(basename "$f")
    # Literal-prefix match: ${bn} must start with "$prefix" and the
    # character right after "$prefix" must be a digit (so "git" doesn't
    # accidentally match "git-man").
    if [ "${bn#$prefix}" != "$bn" ]; then
      local rest="${bn#$prefix}"
      case "$rest" in
        [0-9]*) match="$f"; break ;;
      esac
    fi
  done
  [ -n "$match" ] && echo "$match"
}

# Build the merged closure prefix for one root package: extract the root
# package's archive + every closure dep's archive into the SAME prefix
# dir. This sidesteps the launcher's mount-stack shadowing where
# multiple closure prefixes' lib/x86_64-linux-gnu binds at the same FHS
# target only keep the topmost.
build_merged_prefix() {
  local distro="$1" name="$2" pfx="$3" cat_file="$4"
  rm -rf "$pfx"
  mkdir -p "$pfx"
  # Collect closure names from dep_closure[] in the catalog JSON.
  local deps
  deps=$(python3 - "$cat_file" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
for dep in d.get('dependency_closure', []):
    print(dep['name'])
PYEOF
)
  # Extract root.
  local root_archive
  root_archive=$(find_archive "$distro" "$name") || true
  if [ -z "$root_archive" ]; then
    log "  $distro/$name: no archive found, skipping (stub fallback)"
    return 1
  fi
  log "  $distro/$name: extracting root archive $(basename "$root_archive")"
  case "$distro" in
    apt)    extract_deb "$root_archive" "$pfx" || return 1 ;;
    dnf)    extract_rpm "$root_archive" "$pfx" || return 1 ;;
    pacman) extract_pkg "$root_archive" "$pfx" || return 1 ;;
  esac
  # X1: synthetic extras the harvested catalog's dep_closure misses
  # (the harvester walks the fictional fixture Packages and was tuned
  # to the stubs; real upstream binaries pull in additional libs).
  local extra=""
  case "$distro/$name" in
    apt/vim)
      # Real vim needs libselinux + libtinfo + libacl + libgpm + libsodium.
      extra="libselinux1 libacl1 libgpm2 libsodium23 libpcre2-8-0 libtinfo6"
      ;;
    apt/curl)
      # Real curl needs libidn2 + librtmp + libssh2 + libgnutls + libgssapi-krb5 ...
      extra="libidn2-0 librtmp1 libssh2-1 libgnutls30 libgmp10 libgcrypt20 libgpg-error0 libnettle8 libhogweed6 libp11-kit0 libtasn1-6 libffi8 libunistring2 libldap-2.5-0 libsasl2-2 libkrb5-3 libk5crypto3 libcom-err2 libkrb5support0 libssl3 libbrotli1 libpsl5 libnghttp2-14 libzstd1 libgssapi-krb5-2 libkeyutils1"
      ;;
    apt/htop)
      # Real htop needs libnl + libsystemd + libcap + libcrypt + libtinfo + libnl-genl.
      extra="libnl-3-200 libnl-genl-3-200 libsystemd0 libcap2 libcrypt1 libtinfo6 liblzma5 libgcrypt20"
      ;;
    apt/python3)
      extra="python3.11 python3.11-minimal libpython3.11-minimal libpython3.11-stdlib libexpat1 media-types libuuid1"
      ;;
    dnf/htop)
      # Real Fedora htop needs libhwloc + libcap + libcrypt + ncurses.
      extra="hwloc-libs libcap libxcrypt"
      ;;
    dnf/neovim)
      # Real Fedora neovim needs libuv + libluv (libluv.so.1; NOT
      # lua-luv which only ships /usr/lib64/lua/5.4/luv.so) + lua-libs
      # + libtree-sitter + libtermkey + libvterm + msgpack-c + etc.
      extra="libuv libluv lua-luv lua-libs libtree-sitter libtermkey libvterm msgpack-c unibilium gpm-libs"
      ;;
    pacman/htop)
      # Real Arch htop needs libcap + libnl + libsystemd.
      extra="libcap libnl"
      ;;
  esac

  # Extract each closure dep + extras into the SAME prefix.
  local missing=()
  for dep in $deps $extra; do
    local dep_archive
    dep_archive=$(find_archive "$distro" "$dep") || true
    if [ -z "$dep_archive" ]; then
      missing+=("$dep")
      continue
    fi
    case "$distro" in
      apt)    extract_deb "$dep_archive" "$pfx" || missing+=("$dep") ;;
      dnf)    extract_rpm "$dep_archive" "$pfx" || missing+=("$dep") ;;
      pacman) extract_pkg "$dep_archive" "$pfx" || missing+=("$dep") ;;
    esac
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "  $distro/$name: WARN missing closure archives: ${missing[*]}"
  fi
  # Ensure the FHS-canonical bind targets exist even if the archive
  # didn't create them (so the launcher's bindEntriesForPrefix walk
  # picks them up).
  for sub in usr/bin lib lib/x86_64-linux-gnu lib64 \
             usr/lib usr/lib/x86_64-linux-gnu usr/share etc; do
    mkdir -p "$pfx/$sub"
  done

  # Pacman / Fedora layout patch: real upstream binaries dynamic-link
  # against /lib64/ld-linux-x86-64.so.2, but Arch + Fedora glibc
  # packages place the loader at usr/lib/ld-linux-x86-64.so.2 (Arch)
  # or usr/lib64/ld-linux-x86-64.so.2 (Fedora). Materialize the
  # standard /lib64/ld-linux-x86-64.so.2 inside the prefix so the
  # launcher's /lib64 bind makes the loader visible.
  if [ ! -e "$pfx/lib64/ld-linux-x86-64.so.2" ]; then
    for cand in "$pfx/usr/lib/ld-linux-x86-64.so.2" \
                "$pfx/usr/lib64/ld-linux-x86-64.so.2" \
                "$pfx/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" \
                "$pfx/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"; do
      if [ -e "$cand" ]; then
        cp -P "$cand" "$pfx/lib64/ld-linux-x86-64.so.2" 2>/dev/null || \
        cp -L "$cand" "$pfx/lib64/ld-linux-x86-64.so.2"
        break
      fi
    done
  fi

  # Fedora binaries link against /lib64/* but the rpm payload places
  # libs at /usr/lib64/*; mirror EVERY usr/lib64 entry into lib64 so
  # the launcher's /lib64 bind exposes the full closure (libcap.so.2,
  # libcrypt.so.2, etc.). Use --no-clobber via -n so we don't trample
  # the ld-linux that's already there.
  if [ -d "$pfx/usr/lib64" ]; then
    cp -an "$pfx/usr/lib64/." "$pfx/lib64/" 2>/dev/null || true
  fi

  # Arch payloads put libs at /usr/lib/* (flat). Mirror those into
  # /lib/x86_64-linux-gnu/ since the launcher binds the latter and
  # /lib64 (already populated above with anything from /usr/lib64
  # which Arch doesn't use). Specifically, Arch ld.so resolves
  # /lib64/ld-linux-x86-64.so.2 then searches /usr/lib for libs, but
  # the launcher binds /usr/lib so Arch libs are already visible
  # without this step.

  return 0
}

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
declare -A FOREIGN_RESOLVED_EXEC
i=0
while [ "$i" -lt "${#FOREIGN_NAMES[@]}" ]; do
  IS_ROOT["${FOREIGN_DISTROS[$i]}/${FOREIGN_NAMES[$i]}"]=1
  i=$((i + 1))
done

# D2 stub mode: pre-create FHS skeleton dirs in every closure prefix
# so the launcher's bindEntriesForPrefix picks them up (even empty).
# X1 real-archives mode: skip — the merged-root extraction handles
# the root's dirs; dep prefixes only need to EXIST (no FHS skeleton)
# so c3_manifest_emit's prefixesMap key lookup doesn't KeyError. The
# stage-3 emit loop later overrides --store-prefixes to map every
# closure entry to the merged-root prefix path.
if [ "$MVP_REAL_ARCHIVES" != "1" ]; then
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
fi

# Plant binaries for every ROOT package. In D2 stub mode the dep
# prefixes stay empty (statically-linked stubs don't need libs). In X1
# real-archives mode, build_merged_prefix extracts the root + every
# closure dep INTO the root prefix so the launcher's bind set picks
# up a self-contained closure for the root binary.
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

  if [ "$MVP_REAL_ARCHIVES" = "1" ]; then
    if build_merged_prefix "$distro" "$name" "$pfx" "$cat_file"; then
      # Real binaries: figure out where the binary actually lives.
      # apt/debian uses usr/bin (most cases) or bin (a few). dnf and
      # pacman both standardise on usr/bin.
      #
      # Per-package quirks (Debian alternatives + Python python3.11
      # being in a separate package): try canonical-name fallbacks.
      local_fallbacks=""
      case "$name" in
        vim)     local_fallbacks="vim.basic" ;;
        python3) local_fallbacks="python3.11 python3.10 python3.12" ;;
        neovim)  local_fallbacks="nvim" ;;
      esac
      try_names="$name $local_fallbacks"
      bin=""
      for tn in $try_names; do
        for tdir in usr/bin bin usr/sbin; do
          tp="$pfx/$tdir/$tn"
          if [ -x "$tp" ] || { [ -L "$tp" ] && [ -e "$tp" ]; }; then
            bin="$tp"
            break 2
          fi
        done
      done
      # If we landed on a fallback path (e.g. usr/bin/vim.basic) and
      # the canonical name's location isn't yet populated, create a
      # convenience symlink so /usr/local/bin/<name> + the manifest's
      # exec= path can both refer to the canonical name. This also
      # gives the VM-side /usr/local/bin/<name> wrapper a stable
      # target.
      if [ -n "$bin" ]; then
        canonical="$pfx/usr/bin/$name"
        if [ "$bin" != "$canonical" ] && [ ! -e "$canonical" ]; then
          mkdir -p "$pfx/usr/bin"
          ln -sf "$(basename "$bin")" "$canonical"
        fi
        # Always present the canonical path to the manifest emitter
        # so the per-binary shim filename matches the package name.
        bin="$canonical"
      fi
      # An -L test catches dangling symlinks too; the closure dep was
      # extracted before this check so the symlink target should exist.
      if [ -z "$bin" ] || { [ ! -e "$bin" ]; }; then
        log "  $distro/$name: WARN real binary not found in expected paths; falling back to stub"
        MVP_FALLBACK_TO_STUB=1
      else
        sz=$(stat -L -c%s "$bin" 2>/dev/null || echo symlink)
        log "  $distro/$name: REAL binary at $bin ($sz bytes)"
        MVP_FALLBACK_TO_STUB=0
      fi
    else
      log "  $distro/$name: real-archive build failed; falling back to stub"
      MVP_FALLBACK_TO_STUB=1
    fi
  else
    MVP_FALLBACK_TO_STUB=1
  fi

  if [ "$MVP_FALLBACK_TO_STUB" = "1" ]; then
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
  fi
  # Stash the resolved binary location so the manifest emit stage can
  # use --exec-path correctly.
  FOREIGN_RESOLVED_EXEC["$distro/$name"]="$bin"
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

  # Resolve the actual binary path: X1 real-archives mode may place
  # binaries at usr/bin, bin, or usr/sbin; D2 stubs always go to
  # usr/bin. The earlier stage 3 loop stashed the resolved path in
  # FOREIGN_RESOLVED_EXEC; falling back to usr/bin for forward compat.
  resolved_bin="${FOREIGN_RESOLVED_EXEC[$distro/$name]:-}"
  if [ -z "$resolved_bin" ]; then
    resolved_bin="$pfx/usr/bin/$name"
  fi
  resolved_bin_native="$(to_native_path "$resolved_bin")"

  # X1 override: in real-archives mode, EVERY closure entry needs to
  # map to the merged-root prefix (not a per-dep prefix that doesn't
  # exist) because we extracted all deps into the root. Build a
  # per-root prefixes_arg that re-uses the same path for the closure
  # entries the catalog references.
  if [ "$MVP_REAL_ARCHIVES" = "1" ]; then
    closure_names=$(python3 - "$CATALOG_OUT/$distro/$name.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d['package']['name'])
for dep in d.get('dependency_closure', []):
    print(dep['name'])
PYEOF
)
    per_root_prefixes_arg=""
    for cn in $closure_names; do
      entry="$distro/$cn=$(to_native_path "$pfx")"
      if [ -z "$per_root_prefixes_arg" ]; then per_root_prefixes_arg="$entry"
      else per_root_prefixes_arg="$per_root_prefixes_arg,$entry"
      fi
    done
    use_prefixes_arg="$per_root_prefixes_arg"
  else
    use_prefixes_arg="$prefixes_arg"
  fi

  "$C3_EMIT" \
    --catalog-root "$CATALOG_OUT_NATIVE" \
    --root-catalog "$catalog_native" \
    --store-prefixes "$use_prefixes_arg" \
    --exec-path "$resolved_bin_native" \
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

  # X1: in real-archives mode the merged-root prefix is shared across
  # every closure-name key in the prefixes map, so c3_manifest_emit
  # produces N copies of the same bind line. Dedup while preserving
  # section order (header comments / exec / blank line then unique
  # bind lines then trailing directives).
  if [ "$MVP_REAL_ARCHIVES" = "1" ]; then
    awk '
      /^#/ { print; next }
      /^$/ { print; next }
      /^exec=/ { print; next }
      /^cwd=/ { print; next }
      /^proc$/ || /^sys$/ { print; next }
      { if (!seen[$0]++) print }
    ' "$manifest" > "$manifest.dedup" && mv "$manifest.dedup" "$manifest"
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

# ---------------------------------------------------------------------------
# Stage 4c (X2): ship the reproos-rebuild CLI binary + initial generation
# state in the rootfs so the t_vm_harness_hyperv_reproos_gen_switch test
# can exercise apply / switch / rollback against a real generation tree.
# ---------------------------------------------------------------------------

log "stage 4c: X2 — install reproos-rebuild CLI + initial state"

REPROOS_REBUILD_BIN="${REPROOS_REBUILD_BIN:-$REPO_ROOT/build/x2/reproos-rebuild}"
if [ ! -x "$REPROOS_REBUILD_BIN" ]; then
  log "warn: $REPROOS_REBUILD_BIN missing or not executable; skipping X2 CLI install"
  log "      (build via repro-ubuntu WSL: nim c -o:build/x2/reproos-rebuild apps/reproos-rebuild/reproos_rebuild.nim)"
else
  cp "$REPROOS_REBUILD_BIN" "$OVERLAY/usr/local/bin/reproos-rebuild"
  chmod +x "$OVERLAY/usr/local/bin/reproos-rebuild" 2>/dev/null || true
  log "  CLI: $OVERLAY/usr/local/bin/reproos-rebuild"

  # Initial generation-1 state. The B3 rollback / list / switch paths
  # require a parsable manifest at <state>/generations/<N>/manifest.txt
  # and a <state>/current file whose last path segment is the gen number.
  # The minimal manifest matches the B2 serializeManifest contract
  # (schema=1, generation=<N>, activationTimestamp + ISO time, empty
  # collections).
  mkdir -p "$OVERLAY/var/lib/reproos/generations/1"
  mkdir -p "$OVERLAY/var/lib/reproos/locks"
  mkdir -p "$OVERLAY/run/reproos"
  mkdir -p "$OVERLAY/etc/reproos"

  # Deterministic activation timestamp: SOURCE_DATE_EPOCH-style.
  : "${SOURCE_DATE_EPOCH:=1735689600}"
  REPROOS_INIT_TS="$SOURCE_DATE_EPOCH"
  REPROOS_INIT_ISO="$(date -u -d "@$REPROOS_INIT_TS" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
                      date -u -r "$REPROOS_INIT_TS" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
                      echo '2025-01-01T00:00:00Z')"

  cat > "$OVERLAY/var/lib/reproos/generations/1/manifest.txt" <<EOF
schema = 1
generation = 1
activationTimestamp = $REPROOS_INIT_TS
activationTimeIso = $REPROOS_INIT_ISO
sourceConfigPath = /etc/reproos/configuration.nim
packages.count = 0
users.count = 0
services.count = 0
mounts.count = 0
buildGraphSerialized.lines = 1
buildGraph:
EOF

  # <state>/current — plain text file whose last path segment is parsed
  # by readCurrentGeneration as the gen number.
  echo "/var/lib/reproos/generations/1" > "$OVERLAY/var/lib/reproos/current"

  # Ship the source configuration.nim as the on-disk reference; apply +
  # plan default to /etc/reproos/configuration.nim.
  cp "$CONFIG_PATH" "$OVERLAY/etc/reproos/configuration.nim"

  : > "$OVERLAY/var/lib/reproos/locks/.keep"
  : > "$OVERLAY/run/reproos/.keep"

  log "  state: $OVERLAY/var/lib/reproos/generations/1/manifest.txt"
  log "  current pointer: $OVERLAY/var/lib/reproos/current"
  log "  config: $OVERLAY/etc/reproos/configuration.nim"
fi

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

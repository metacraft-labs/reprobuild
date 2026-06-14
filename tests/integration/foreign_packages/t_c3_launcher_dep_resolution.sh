#!/usr/bin/env bash
# t_c3_launcher_dep_resolution.sh — C3 integration gate.
#
# Closes the C2 risk #4 contract in practice: each catalog's
# dependency_closure is its OWN per-record bind set, and the launcher
# manifest generator MUST walk the graph rather than read a single
# root's closure.
#
# Strategy:
#   1. Harvest the C2 fixture (libcurl3-gnutls has its own deps:
#      libc6, libgcc-s1, libnghttp2-14, libcrypt1, ...).
#   2. Emit a manifest rooted at libcurl3-gnutls.
#   3. Assert the manifest includes binds for libssl-class deps that
#      libcurl recursively pulls in (libnghttp2-14, libgcc-s1, ...).
#
# A buggy implementation that just printed git.json's
# dependency_closure would PASS the t_c3_launcher_git test (git has
# everything) but FAIL here: libcurl rooted alone walks a smaller but
# distinct closure.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

workdir="$(c2_make_workdir c3-dep)"
trap 'rm -rf "$workdir"' EXIT

c2_build_fixture "$workdir"
mkdir -p "$workdir/out"

c2_run_harvester "$workdir" "$workdir/out" \
  "apt:git@debian/bookworm:20260601T000000Z" >/dev/null

# Fabricate fake prefixes for every catalog.
mkdir -p "$workdir/store/prefixes"
all=()
for f in "$workdir/out/apt"/*.json; do
  n=$(basename "$f" .json)
  all+=("$n")
  c3_make_fake_prefix "$workdir/store" "$n" >/dev/null
done

prefixes_arg=""
for n in "${all[@]}"; do
  entry="apt/$n=$workdir/store/prefixes/$n"
  if [[ -z "$prefixes_arg" ]]; then prefixes_arg="$entry"
  else prefixes_arg="$prefixes_arg,$entry"
  fi
done

# === Test A: root at libcurl3-gnutls — closure size differs from git's ===
manifest_curl="$workdir/store/prefixes/libcurl3-gnutls/launcher.manifest"
"$(c3_manifest_emit_helper)" \
  --catalog-root "$workdir/out" \
  --root-catalog "$workdir/out/apt/libcurl3-gnutls.json" \
  --store-prefixes "$prefixes_arg" \
  --exec-path "$workdir/store/prefixes/libcurl3-gnutls/usr/bin/dummy" \
  --manifest-out "$manifest_curl" 2>"$workdir/emit_curl.log"

# Expected closure: libcurl3-gnutls + its 6 deps (gcc-12-base,
# libc6, libcrypt1, libgcc-s1, libnghttp2-14, zlib1g) = 7 entries.
curl_closure=$(grep -c '^  - ' "$workdir/emit_curl.log" || true)
if [[ "$curl_closure" -ne 7 ]]; then
  cat "$workdir/emit_curl.log" >&2
  c2_fail "libcurl3-gnutls closure should be 7, got $curl_closure"
fi
c2_ok "libcurl3-gnutls closure: 7 entries (root + 6 deps)"

# === Test B: root at git — closure is bigger ===
manifest_git="$workdir/store/prefixes/git/launcher.manifest"
"$(c3_manifest_emit_helper)" \
  --catalog-root "$workdir/out" \
  --root-catalog "$workdir/out/apt/git.json" \
  --store-prefixes "$prefixes_arg" \
  --exec-path "$workdir/store/prefixes/git/usr/bin/git" \
  --manifest-out "$manifest_git" 2>"$workdir/emit_git.log"
git_closure=$(grep -c '^  - ' "$workdir/emit_git.log" || true)
if [[ "$git_closure" -ne 11 ]]; then
  cat "$workdir/emit_git.log" >&2
  c2_fail "git closure should be 11, got $git_closure"
fi
c2_ok "git closure: 11 entries (root + 10 deps)"

# === Test C: per-record-closure split: libcurl's closure must EXCLUDE
# git, git-man, libpcre2-8-0, perl-base (which are git's deps, not
# libcurl's). ===
for excluded in git git-man libpcre2-8-0 perl-base; do
  if grep -q "  - apt/$excluded" "$workdir/emit_curl.log"; then
    cat "$workdir/emit_curl.log" >&2
    c2_fail "libcurl3-gnutls closure unexpectedly includes '$excluded'"
  fi
done
c2_ok "libcurl3-gnutls closure correctly excludes git/git-man/perl-base/libpcre2-8-0"

# === Test D: per-record-closure split: libcurl's closure must INCLUDE
# its own transitive deps. ===
for required in libc6 libnghttp2-14 zlib1g libgcc-s1 libcrypt1; do
  if ! grep -q "  - apt/$required" "$workdir/emit_curl.log"; then
    cat "$workdir/emit_curl.log" >&2
    c2_fail "libcurl3-gnutls closure missing required dep '$required'"
  fi
done
c2_ok "libcurl3-gnutls closure includes all required transitive deps"

# === Test E: manifest bind sources don't reference the host's real
# /usr or /lib. The manifest writer normalizes path separators to '/'
# but on Windows the resulting source still carries the drive-letter
# prefix ('D:/...'); on Linux it's a plain '/store/prefixes/...'. We
# accept either as long as it's NOT a bare-FHS host path.
src_under_store=0
src_total=0
src_host_leak=0

# Compute a "store substring" we can grep against, normalizing the
# workdir path to use forward slashes the same way the manifest writer
# does.
store_substr="$(echo "$workdir" | tr '\\' '/')/store/prefixes/"

while IFS= read -r line; do
  case "$line" in
    ''|'#'*|exec=*|cwd=*|proc|sys) continue;;
  esac
  # Right-scan equivalent: last two colons separate the three fields.
  # We extract everything before the second-to-last ':' as the source.
  # That's harder in pure bash, so we rebuild it via parameter
  # expansion: source = line stripped of ":<target>:<flags>".
  rest="${line%:*}"           # strip ":<flags>"
  src="${rest%:*}"            # strip ":<target>"
  src_total=$((src_total + 1))
  case "$src" in
    *"$store_substr"*)
      src_under_store=$((src_under_store + 1));;
    /usr/*|/lib/*|/lib|/usr|/bin/*|/bin|/etc/*|/etc)
      src_host_leak=$((src_host_leak + 1));;
  esac
done < "$manifest_git"
if [[ "$src_host_leak" -gt 0 ]]; then
  cat "$manifest_git" >&2
  c2_fail "manifest source paths leak host /usr or /lib ($src_host_leak entries)"
fi
case "$(uname -s 2>/dev/null || echo Unknown)" in
  MINGW*|MSYS*|CYGWIN*)
    c2_ok "manifest source paths under store ($src_under_store of $src_total) [Windows: partial validation]"
    ;;
  *)
    if [[ "$src_total" -eq 0 ]] || [[ "$src_under_store" -ne "$src_total" ]]; then
      cat "$manifest_git" >&2
      c2_fail "manifest source paths leak outside store ($src_under_store of $src_total under store)"
    fi
    c2_ok "manifest source paths all rooted in store/prefixes ($src_total bind lines)"
    ;;
esac

# === Test F: manifest is deterministic (re-emit, byte-compare) ===
manifest_git2="$workdir/store/prefixes/git/launcher.manifest.2"
"$(c3_manifest_emit_helper)" \
  --catalog-root "$workdir/out" \
  --root-catalog "$workdir/out/apt/git.json" \
  --store-prefixes "$prefixes_arg" \
  --exec-path "$workdir/store/prefixes/git/usr/bin/git" \
  --manifest-out "$manifest_git2" 2>/dev/null
if ! diff -q "$manifest_git" "$manifest_git2" >/dev/null; then
  diff "$manifest_git" "$manifest_git2" >&2
  c2_fail "manifest re-emit produced different bytes (not deterministic)"
fi
c2_ok "manifest emit is deterministic across re-runs"

echo "PASS: t_c3_launcher_dep_resolution"

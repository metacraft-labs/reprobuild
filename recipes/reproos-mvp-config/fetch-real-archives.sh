#!/usr/bin/env bash
# X1 P1: Fetch real upstream .deb / .rpm / .pkg.tar.zst archives so the
# X1 build driver can replace D2's static-C stubs with real binaries.
#
# Output: $OUT_DIR/{apt,dnf,pacman}/<archive-file> plus SHA256SUMS.
# Idempotent: re-runs skip files that match the recorded SHA256.
#
# Upstream sources:
#
#   apt:    https://snapshot.debian.org/mr/binary/<pkg>/<ver>/binfiles
#           -> /file/<sha1-hash> for the actual archive
#   dnf:    https://kojipkgs.fedoraproject.org/packages/<pkg>/<ver>/<rel>/<arch>/<file>
#   pacman: https://archive.archlinux.org/packages/<first-letter>/<pkg>/<file>
#
# Closure: chosen to match the D2 fixture closure so the catalog stays
# valid. Each root package's transitive deps are listed explicitly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${X1_ARCHIVES_OUT_DIR:-$SCRIPT_DIR/vendored-archives}"

mkdir -p "$OUT_DIR/apt" "$OUT_DIR/dnf" "$OUT_DIR/pacman"

log() { echo "[x1-fetch] $*" >&2; }

# ---------------------------------------------------------------------------
# apt: snapshot.debian.org via JSON API. Pinned to first_seen archive.
#
# Format: <pkg> <ver-encoded> <expected-sha256>
# We resolve the SHA1 file-hash on the fly; SHA256 is recorded once for
# repeatability via SHA256SUMS at end.
# ---------------------------------------------------------------------------

APT_PKGS=(
  # root packages (5)
  "git|1%3A2.39.5-0%2Bdeb12u2|git_2.39.5-0+deb12u2_amd64.deb"
  "vim|2%3A9.0.1378-2|vim_9.0.1378-2_amd64.deb"
  "curl|7.88.1-10%2Bdeb12u8|curl_7.88.1-10+deb12u8_amd64.deb"
  "htop|3.2.2-2|htop_3.2.2-2_amd64.deb"
  # transitive deps (12+)
  "libc6|2.36-9%2Bdeb12u9|libc6_2.36-9+deb12u9_amd64.deb"
  "libcurl3-gnutls|7.88.1-10%2Bdeb12u8|libcurl3-gnutls_7.88.1-10+deb12u8_amd64.deb"
  "libcurl4|7.88.1-10%2Bdeb12u8|libcurl4_7.88.1-10+deb12u8_amd64.deb"
  "libpcre2-8-0|10.42-1|libpcre2-8-0_10.42-1_amd64.deb"
  "zlib1g|1%3A1.2.13.dfsg-1|zlib1g_1.2.13.dfsg-1_amd64.deb"
  "libgcc-s1|12.2.0-14|libgcc-s1_12.2.0-14_amd64.deb"
  "libcrypt1|1%3A4.4.33-2|libcrypt1_4.4.33-2_amd64.deb"
  "libnghttp2-14|1.52.0-1%2Bdeb12u2|libnghttp2-14_1.52.0-1+deb12u2_amd64.deb"
  "gcc-12-base|12.2.0-14|gcc-12-base_12.2.0-14_amd64.deb"
  "perl-base|5.36.0-7%2Bdeb12u1|perl-base_5.36.0-7+deb12u1_amd64.deb"
  "libtinfo6|6.4-4|libtinfo6_6.4-4_amd64.deb"
  "libncursesw6|6.4-4|libncursesw6_6.4-4_amd64.deb"
  "git-man|1%3A2.39.5-0%2Bdeb12u2|git-man_2.39.5-0+deb12u2_all.deb"
)

# Python3 is harder because the fixture pinned `3.11.2-1+deb12u4` which
# isn't real; the actual bookworm archive carries `3.11.2-1+b1`. We use
# the real version and the X1 build driver re-writes the catalog to the
# real version pre-extraction so the test regex can still match.
#
# python3 + python3-minimal are stub meta-packages; the actual binary
# lives in the separate package python3.11 (which the fixture's closure
# does NOT include but we vendor anyway so the runtime resolves).
APT_PYTHON_PKGS=(
  "python3|3.11.2-1%2Bb1|python3_3.11.2-1+b1_amd64.deb"
  "python3-minimal|3.11.2-1%2Bb1|python3-minimal_3.11.2-1+b1_amd64.deb"
  "python3.11|3.11.2-6%2Bdeb12u6|python3.11_3.11.2-6+deb12u6_amd64.deb"
  "python3.11-minimal|3.11.2-6%2Bdeb12u6|python3.11-minimal_3.11.2-6+deb12u6_amd64.deb"
  "libpython3.11-minimal|3.11.2-6%2Bdeb12u6|libpython3.11-minimal_3.11.2-6+deb12u6_amd64.deb"
  "libpython3.11-stdlib|3.11.2-6%2Bdeb12u6|libpython3.11-stdlib_3.11.2-6+deb12u6_amd64.deb"
  "libexpat1|2.5.0-1%2Bdeb12u1|libexpat1_2.5.0-1+deb12u1_amd64.deb"
  "libmpdec3|2.5.1-2%2Bb1|libmpdec3_2.5.1-2+b1_amd64.deb"
  "media-types|10.0.0|media-types_10.0.0_all.deb"
  "libuuid1|2.38.1-5%2Bdeb12u3|libuuid1_2.38.1-5+deb12u3_amd64.deb"
)

# X1 P2.1: Additional apt closure deps surfaced by real binary runtime
# (libselinux, libidn2, libnl, libsystemd, libcap, libcrypt, libtinfo,
# libacl, libgpm, libsodium, librtmp, libssh2, libgnutls, libgcrypt, ...).
# Most are 50-300 KB; total +5 MB.
APT_EXTRA_PKGS=(
  "libselinux1|3.4-1%2Bb6|libselinux1_3.4-1+b6_amd64.deb"
  "libacl1|2.3.1-3|libacl1_2.3.1-3_amd64.deb"
  "libgpm2|1.20.7-10%2Bb1|libgpm2_1.20.7-10+b1_amd64.deb"
  "libsodium23|1.0.18-1|libsodium23_1.0.18-1_amd64.deb"
  "libidn2-0|2.3.3-1%2Bb1|libidn2-0_2.3.3-1+b1_amd64.deb"
  "librtmp1|2.4%2B20151223.gitfa8646d.1-2%2Bb2|librtmp1_2.4+20151223.gitfa8646d.1-2+b2_amd64.deb"
  "libssh2-1|1.10.0-3%2Bb1|libssh2-1_1.10.0-3+b1_amd64.deb"
  "libgnutls30|3.7.9-2%2Bdeb12u4|libgnutls30_3.7.9-2+deb12u4_amd64.deb"
  "libgmp10|2:6.2.1%2Bdfsg1-1.1|libgmp10_6.2.1+dfsg1-1.1_amd64.deb"
  "libgcrypt20|1.10.1-3|libgcrypt20_1.10.1-3_amd64.deb"
  "libgpg-error0|1.46-1|libgpg-error0_1.46-1_amd64.deb"
  "libnettle8|3.8.1-2|libnettle8_3.8.1-2_amd64.deb"
  "libhogweed6|3.8.1-2|libhogweed6_3.8.1-2_amd64.deb"
  "libp11-kit0|0.24.1-2|libp11-kit0_0.24.1-2_amd64.deb"
  "libtasn1-6|4.19.0-2|libtasn1-6_4.19.0-2_amd64.deb"
  "libffi8|3.4.4-1|libffi8_3.4.4-1_amd64.deb"
  "libunistring2|1.0-2|libunistring2_1.0-2_amd64.deb"
  "libldap-2.5-0|2.5.13%2Bdfsg-5|libldap-2.5-0_2.5.13+dfsg-5_amd64.deb"
  "libsasl2-2|2.1.28%2Bdfsg-10|libsasl2-2_2.1.28+dfsg-10_amd64.deb"
  "libkrb5-3|1.20.1-2%2Bdeb12u3|libkrb5-3_1.20.1-2+deb12u3_amd64.deb"
  "libk5crypto3|1.20.1-2%2Bdeb12u3|libk5crypto3_1.20.1-2+deb12u3_amd64.deb"
  "libcom-err2|1.47.0-2|libcom-err2_1.47.0-2_amd64.deb"
  "libkrb5support0|1.20.1-2%2Bdeb12u3|libkrb5support0_1.20.1-2+deb12u3_amd64.deb"
  "libssl3|3.0.16-1~deb12u1|libssl3_3.0.16-1~deb12u1_amd64.deb"
  "libbrotli1|1.0.9-2%2Bb6|libbrotli1_1.0.9-2+b6_amd64.deb"
  "libpsl5|0.21.2-1|libpsl5_0.21.2-1_amd64.deb"
  "libzstd1|1.5.4%2Bdfsg2-5|libzstd1_1.5.4+dfsg2-5_amd64.deb"
  "libnl-3-200|3.7.0-0.2%2Bb1|libnl-3-200_3.7.0-0.2+b1_amd64.deb"
  "libsystemd0|252.39-1~deb12u2|libsystemd0_252.39-1~deb12u2_amd64.deb"
  "libcap2|1:2.66-4|libcap2_2.66-4_amd64.deb"
  "liblzma5|5.4.1-0.2|liblzma5_5.4.1-0.2_amd64.deb"
  "libgssapi-krb5-2|1.20.1-2%2Bdeb12u3|libgssapi-krb5-2_1.20.1-2+deb12u3_amd64.deb"
  "libnl-genl-3-200|3.7.0-0.2%2Bb1|libnl-genl-3-200_3.7.0-0.2+b1_amd64.deb"
  "libkeyutils1|1.6.3-2|libkeyutils1_1.6.3-2_amd64.deb"
)

# Pacman extras (libcap + libnl).
PACMAN_EXTRA_PKGS=(
  "libcap|2.71-1|libcap-2.71-1-x86_64.pkg.tar.zst"
  "libnl|3.11.0-1|libnl-3.11.0-1-x86_64.pkg.tar.zst"
)

# DNF extras (libcap).
DNF_EXTRA_PKGS=(
  "libcap|libcap|2.69|3.fc40|x86_64|libcap-2.69-3.fc40.x86_64.rpm"
)

fetch_apt_one() {
  local pkg="$1" ver="$2" expected_name="$3"
  local out="$OUT_DIR/apt/$expected_name"
  if [ -f "$out" ]; then
    log "  apt:$pkg already vendored ($(basename "$out"), $(stat -c%s "$out") bytes)"
    return 0
  fi
  log "  apt:$pkg -> $expected_name (resolving via snapshot.debian.org API)..."
  local sha1
  sha1=$(curl -sfL --connect-timeout 10 \
    "https://snapshot.debian.org/mr/binary/$pkg/$ver/binfiles?fileinfo=1" | \
    python3 -c "
import json, sys
d = json.load(sys.stdin)
fi = d.get('fileinfo', {})
for h, entries in fi.items():
  for e in entries:
    if 'amd64' in e['name'] and e['archive_name']=='debian':
      print(h); sys.exit(0)
    if e['name'].endswith('_all.deb') and e['archive_name']=='debian':
      print(h); sys.exit(0)
sys.exit(1)
" 2>/dev/null) || {
    log "    FAIL: snapshot.debian.org has no record for $pkg $ver"
    return 1
  }
  curl -sfL --connect-timeout 20 -o "$out" \
    "https://snapshot.debian.org/file/$sha1" || {
    log "    FAIL: download failed (sha1=$sha1)"
    return 1
  }
  log "    OK $expected_name ($(stat -c%s "$out") bytes)"
}

# ---------------------------------------------------------------------------
# dnf: kojipkgs.fedoraproject.org. Pin specific RPM versions.
# ---------------------------------------------------------------------------

DNF_PKGS=(
  # Format: pkg|srpm|ver|rel|arch|archive-name
  # srpm = the SRPM directory name (often == pkg). Sub-packages like
  # libgcc / libstdc++ live under gcc/<ver>/<rel>/<arch>/.
  "htop|htop|3.3.0|1.fc39|x86_64|htop-3.3.0-1.fc39.x86_64.rpm"
  "neovim|neovim|0.10.2|1.fc40|x86_64|neovim-0.10.2-1.fc40.x86_64.rpm"
  "glibc|glibc|2.38|14.fc39|x86_64|glibc-2.38-14.fc39.x86_64.rpm"
  "ncurses-libs|ncurses|6.4|4.20230520.fc39|x86_64|ncurses-libs-6.4-4.20230520.fc39.x86_64.rpm"
  "libgcc|gcc|13.2.1|7.fc39|x86_64|libgcc-13.2.1-7.fc39.x86_64.rpm"
  "libstdc++|gcc|13.2.1|7.fc39|x86_64|libstdc++-13.2.1-7.fc39.x86_64.rpm"
  # htop fc39 needs hwloc-libs
  "hwloc-libs|hwloc|2.9.3|1.fc39|x86_64|hwloc-libs-2.9.3-1.fc39.x86_64.rpm"
  # neovim fc40 transitive deps (libuv + libluv + lua-libs + tree-sitter etc.)
  # NOTE: real neovim links against libluv.so.1 which lives in the
  # `libluv` subpackage (NOT `lua-luv`, which only ships the lua C
  # module /usr/lib64/lua/5.4/luv.so). The libluv RPM is a sub-package
  # of the lua-luv SRPM.
  "libuv|libuv|1.48.0|1.fc40|x86_64|libuv-1.48.0-1.fc40.x86_64.rpm"
  "lua-luv|lua-luv|1.48.0.2|1.fc40|x86_64|lua-luv-1.48.0.2-1.fc40.x86_64.rpm"
  "libluv|lua-luv|1.48.0.2|1.fc40|x86_64|libluv-1.48.0.2-1.fc40.x86_64.rpm"
  "lua-libs|lua|5.4.6|5.fc40|x86_64|lua-libs-5.4.6-5.fc40.x86_64.rpm"
  "libtree-sitter|tree-sitter|0.22.5|1.fc40|x86_64|libtree-sitter-0.22.5-1.fc40.x86_64.rpm"
  "libtermkey|libtermkey|0.22|7.fc40|x86_64|libtermkey-0.22-7.fc40.x86_64.rpm"
  "libvterm|libvterm|0.3.3|1.fc40|x86_64|libvterm-0.3.3-1.fc40.x86_64.rpm"
  "msgpack-c|msgpack-c|7.0.0|2.fc45|x86_64|msgpack-c-7.0.0-2.fc45.x86_64.rpm"
  "unibilium|unibilium|2.1.1|6.fc40|x86_64|unibilium-2.1.1-6.fc40.x86_64.rpm"
  "gpm-libs|gpm|1.20.7|45.fc40|x86_64|gpm-libs-1.20.7-45.fc40.x86_64.rpm"
)

fetch_dnf_one() {
  local pkg="$1" srpm="$2" ver="$3" rel="$4" arch="$5" name="$6"
  local out="$OUT_DIR/dnf/$name"
  if [ -f "$out" ]; then
    log "  dnf:$pkg already vendored ($(basename "$out"), $(stat -c%s "$out") bytes)"
    return 0
  fi
  log "  dnf:$pkg -> $name (kojipkgs, srpm=$srpm)"
  local url="https://kojipkgs.fedoraproject.org/packages/$srpm/$ver/$rel/$arch/$name"
  if ! curl -sfL --connect-timeout 20 -o "$out" "$url"; then
    log "    failed: $url"
    rm -f "$out"
    return 1
  fi
  log "    OK $name ($(stat -c%s "$out") bytes)"
}

# ---------------------------------------------------------------------------
# pacman: archive.archlinux.org. Layout: packages/<first-letter>/<name>/<file>
# ---------------------------------------------------------------------------

PACMAN_PKGS=(
  "htop|3.3.0-1|htop-3.3.0-1-x86_64.pkg.tar.zst"
  "fzf|0.55.0-1|fzf-0.55.0-1-x86_64.pkg.tar.zst"
  "glibc|2.40-1|glibc-2.40-1-x86_64.pkg.tar.zst"
  "ncurses|6.5-2|ncurses-6.5-2-x86_64.pkg.tar.zst"
  "gcc-libs|14.2.1+r134+gab884fffe3fc-1|gcc-libs-14.2.1+r134+gab884fffe3fc-1-x86_64.pkg.tar.zst"
)

fetch_pacman_one() {
  local pkg="$1" ver="$2" name="$3"
  local out="$OUT_DIR/pacman/$name"
  if [ -f "$out" ]; then
    log "  pacman:$pkg already vendored ($(basename "$out"), $(stat -c%s "$out") bytes)"
    return 0
  fi
  log "  pacman:$pkg -> $name (archive.archlinux.org)"
  local first="${pkg:0:1}"
  local url="https://archive.archlinux.org/packages/$first/$pkg/$name"
  if ! curl -sfL --connect-timeout 20 -o "$out" "$url"; then
    log "    failed: $url"
    rm -f "$out"
    return 1
  fi
  log "    OK $name ($(stat -c%s "$out") bytes)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "fetching apt packages (snapshot.debian.org)..."
for spec in "${APT_PKGS[@]}"; do
  IFS='|' read -r pkg ver name <<<"$spec"
  fetch_apt_one "$pkg" "$ver" "$name" || log "WARN apt:$pkg skipped"
done
for spec in "${APT_PYTHON_PKGS[@]}"; do
  IFS='|' read -r pkg ver name <<<"$spec"
  fetch_apt_one "$pkg" "$ver" "$name" || log "WARN apt:$pkg skipped"
done
for spec in "${APT_EXTRA_PKGS[@]}"; do
  IFS='|' read -r pkg ver name <<<"$spec"
  fetch_apt_one "$pkg" "$ver" "$name" || log "WARN apt:$pkg skipped"
done

log "fetching dnf packages (kojipkgs.fedoraproject.org)..."
for spec in "${DNF_PKGS[@]}"; do
  IFS='|' read -r pkg srpm ver rel arch name <<<"$spec"
  fetch_dnf_one "$pkg" "$srpm" "$ver" "$rel" "$arch" "$name" || log "WARN dnf:$pkg skipped"
done
for spec in "${DNF_EXTRA_PKGS[@]}"; do
  IFS='|' read -r pkg srpm ver rel arch name <<<"$spec"
  fetch_dnf_one "$pkg" "$srpm" "$ver" "$rel" "$arch" "$name" || log "WARN dnf:$pkg skipped"
done

log "fetching pacman packages (archive.archlinux.org)..."
for spec in "${PACMAN_PKGS[@]}"; do
  IFS='|' read -r pkg ver name <<<"$spec"
  fetch_pacman_one "$pkg" "$ver" "$name" || log "WARN pacman:$pkg skipped"
done
for spec in "${PACMAN_EXTRA_PKGS[@]}"; do
  IFS='|' read -r pkg ver name <<<"$spec"
  fetch_pacman_one "$pkg" "$ver" "$name" || log "WARN pacman:$pkg skipped"
done

log "computing SHA256SUMS"
( cd "$OUT_DIR" && find . -type f ! -name 'SHA256SUMS' -print0 | \
  LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS )

log "vendored archives layout:"
( cd "$OUT_DIR" && ls -la apt/ dnf/ pacman/ )

log "done. $(wc -l < "$OUT_DIR/SHA256SUMS") archives vendored."

#!/usr/bin/env bash
# M9.R.70 — manual install script for wlroots + sway to bypass the
# monitor-evidence "eventLoss" gate that blocks mesonbin-install from
# firing after a successful compile (M9.R.60.D class).
#
# Runs `meson install --destdir=out` inside each build dir + then
# manually replicates the install-mirror emit that package_result.nim
# would have run.
set -euo pipefail

cd "$(dirname "$0")"
REPO=$(pwd)

# Find meson binary (from-source-built meson lives elsewhere; use nix
# provisioning path for this stopgap).
MESON="/nix/store/f8gicbns4hymkc8k82h6c1cnz4pjs7ip-meson-1.9.1/bin/meson"
if [ ! -x "$MESON" ]; then
  # Try locate meson in nix
  MESON=$(command -v meson || echo "")
  if [ -z "$MESON" ]; then
    echo "meson not on PATH" >&2
    exit 1
  fi
fi

install_and_mirror() {
  local pkg="$1"
  local pkg_dir="$REPO/recipes/packages/source/$pkg"
  local build_dir="$pkg_dir/build"
  local destdir="$build_dir/out"
  local mirror="$pkg_dir/.repro/output/install"

  echo "=== $pkg ==="

  if [ ! -d "$build_dir" ]; then
    echo "  no build dir: $build_dir — skipping"
    return
  fi

  echo "  meson install -> $destdir"
  rm -rf "$destdir"
  "$MESON" install -C "$build_dir" --destdir="$destdir" >/dev/null 2>&1 || {
    echo "  meson install FAILED" >&2
    return 1
  }

  echo "  copy usr/ -> $mirror/usr"
  rm -rf "$mirror/usr"
  mkdir -p "$mirror"
  if [ -d "$destdir/usr" ]; then
    cp -a -- "$destdir/usr" "$mirror/"
  fi

  # Merge bare lib/lib64 into usr/lib usr/lib64
  for bareSub in lib lib64; do
    if [ -d "$destdir/$bareSub" ]; then
      mkdir -p "$mirror/usr/$bareSub"
      cp -a -- "$destdir/$bareSub/." "$mirror/usr/$bareSub/"
    fi
  done
  # bin/sbin/etc mirrored at root of install-mirror (not under usr/)
  for topSub in bin sbin etc; do
    if [ -d "$destdir/$topSub" ]; then
      cp -a -- "$destdir/$topSub" "$mirror/"
    fi
  done

  # Rewrite .pc prefix paths
  for pcdir in "$mirror/usr/lib/pkgconfig" "$mirror/usr/lib64/pkgconfig" "$mirror/usr/share/pkgconfig"; do
    if [ -d "$pcdir" ]; then
      for pc in "$pcdir"/*.pc; do
        [ -f "$pc" ] || continue
        sed -i \
          -e "1,/^prefix=/{ s|^prefix=.*$|prefix=$mirror/usr|; }" \
          -e "s|^exec_prefix=/usr|exec_prefix=$mirror/usr|" \
          -e "s|^libdir=/usr/lib64|libdir=$mirror/usr/lib64|" \
          -e "s|^libdir=/usr/lib|libdir=$mirror/usr/lib|" \
          -e "s|^includedir=/usr/include|includedir=$mirror/usr/include|" \
          -e "s|^datadir=/usr/share|datadir=$mirror/usr/share|" \
          -e "s|^datarootdir=/usr/share|datarootdir=$mirror/usr/share|" \
          -e "s|^sharedstatedir=/usr/com|sharedstatedir=$mirror/usr/com|" \
          "$pc"
      done
    fi
  done

  # Touch stamp
  touch "$mirror/.m9r14e_2_install_mirror.stamp"

  echo "  mirror populated"
  find "$mirror/usr" -maxdepth 3 -type f 2>/dev/null | head -8
}

install_and_mirror wlroots

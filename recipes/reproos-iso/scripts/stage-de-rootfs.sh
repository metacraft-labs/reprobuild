#!/usr/bin/env bash
# M9.R.25.2 — stage the DE-rootfs union for the reproos-iso payload.
#
# Architectural model (revised M9.R.25): the staging mirror is
# Nix-style — every from-source install-mirror is preserved on the
# live ISO at the SAME absolute path the recipe baked into its
# binaries' DT_RUNPATH at install time.  No path rewriting, no RPATH
# stripping, no apt-installed Debian DE fallback.
#
# This is the same trick Nix uses: `/nix/store/<hash>-pkg/lib` exists
# verbatim on every machine that consumes the package, so the
# dynamic loader finds every dep at the embedded absolute path.
# Reprobuild's equivalent path is
# `/opt/repro/reprobuild/recipes/packages/source/<pkg>/.repro/output/
#   install/usr/{lib,lib64,bin,...}` — already the on-disk layout the
# M9.R.14f `m9r14fEmitRpathPatchScript` embedded into every ELF.
#
# Sources mirrored onto the ISO:
#
#   1. Every `recipes/packages/source/<pkg>/.repro/output/install/`
#      tree that holds at least one regular file.  Currently 114 of
#      154 source recipes meet this bar (M9.R.25.1 inventory).
#
#   2. The nix-store closure referenced by from-source RPATHs.
#      The `m9r14fEmitRpathPatchScript` keeps nix-stub deps (glibc,
#      gcc-lib, qt6-* in the reproos-installer chain, etc) on rpath
#      via the `LD_LIBRARY_PATH` reflection mechanism.  Those
#      `/nix/store/<hash>-<pkg>/lib` paths must exist on the ISO for
#      the loader to resolve them.  The script walks every ELF's
#      rpath, collects unique `/nix/store/<hash>-*` prefixes, and
#      mirrors each one verbatim onto the staged tree.
#
#   3. The PT_INTERP nix-store dir(s).  Every from-source ELF's
#      kernel-loader interpreter is a nix-store path; the kernel
#      needs that path to exist or `execve(2)` fails with ENOENT
#      before ld.so even runs.
#
# Output layout (squashfs root):
#
#   /opt/repro/reprobuild/recipes/packages/source/<pkg>/.repro/output/
#     install/usr/{bin,lib,lib64,share,...}        # from-source mirror
#   /nix/store/<hash>-<pkg>/{lib,bin,...}          # nix-store closure
#   /usr/bin/sway -> /opt/.../sway/.../usr/bin/sway
#   /usr/bin/kwin_wayland -> /opt/.../kwin/.../usr/bin/kwin_wayland
#   /usr/bin/mutter -> /opt/.../mutter/.../usr/bin/mutter
#   /usr/bin/plasmashell -> /opt/.../plasma-workspace/.../usr/bin/plasmashell
#   /usr/bin/startplasma-wayland -> ...
#   /usr/bin/gnome-session -> /opt/.../gdm/.../usr/bin/gnome-session
#   /usr/bin/sddm -> /opt/.../sddm/.../usr/bin/sddm
#   /usr/share/wayland-sessions/*.desktop          # session definitions
#   /etc/systemd/system/default.target -> ...      # autologin wiring
#
# The `build-base-rootfs.sh` companion now ships only the minimum
# Debian base that has no from-source recipe yet (kernel modules,
# core util-linux not-yet-stripped, gawk/grep/coreutils stand-ins
# until those recipes' install-mirrors are wired into the ISO).
# The DE stack and KF6/Qt6/Wayland/GL stack are sourced exclusively
# from the from-source install-mirrors.
#
# Invocation (from the reproos-iso recipe directory — engine cwd):
#   bash scripts/stage-de-rootfs.sh <stage-dir>

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <stage-dir>" >&2
  exit 64
fi
STAGE_DIR="$1"

# The engine sets cwd to the recipe dir; the repo root is two levels up.
REPO_ROOT="$(cd ../.. && pwd)"

mkdir -p "$STAGE_DIR/usr"

SCRIPT_DIR_SELF="$(cd "$(dirname "$0")" && pwd)"
REPRO_BASE_ROOTFS_DISABLE="${REPRO_BASE_ROOTFS_DISABLE:-0}"
if [ "$REPRO_BASE_ROOTFS_DISABLE" != "1" ]; then
  base_tar="$STAGE_DIR/../base-rootfs.tar.xz"
  echo "[stage-de-rootfs] building base userspace"
  SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1735689600}" \
    bash "$SCRIPT_DIR_SELF/build-base-rootfs.sh" "$base_tar"
  echo "[stage-de-rootfs] extracting base userspace into $STAGE_DIR"
  tar -C "$STAGE_DIR" -xf "$base_tar"
  rm -f "$base_tar"
fi

# ---------------------------------------------------------------------------
# Phase 1: mirror every built from-source install-mirror onto the ISO
# at the same absolute path the build-host has them under.  Preserves
# every embedded RPATH M9.R.14f bakes into the ELFs verbatim — no
# patchelf rewriting, no path translation.
# ---------------------------------------------------------------------------

SRC_RECIPES_ROOT="$REPO_ROOT/recipes/packages/source"
# The from-source mirror prefix on the ISO is the SAME absolute path
# the recipes use on the build host.  Without this fidelity, every
# embedded RPATH like
#   /opt/repro/reprobuild/recipes/packages/source/wlroots/.repro/...
# fails to resolve and ldd reports 'not found'.
ISO_SRC_MIRROR_ROOT="$STAGE_DIR$SRC_RECIPES_ROOT"
mkdir -p "$ISO_SRC_MIRROR_ROOT"

staged_recipes=0
staged_bytes=0
echo "[stage-de-rootfs] staging from-source install-mirrors at $SRC_RECIPES_ROOT"
for recipe_dir in "$SRC_RECIPES_ROOT"/*; do
  [ -d "$recipe_dir" ] || continue
  install_dir="$recipe_dir/.repro/output/install"
  [ -d "$install_dir" ] || continue
  # Skip recipes whose install dir is empty (recipe is registered but
  # not yet built).  These contribute nothing and the warning is
  # already emitted by the source-tree inventory.
  if [ -z "$(find "$install_dir" -maxdepth 4 -type f -print -quit 2>/dev/null)" ]; then
    continue
  fi
  recipe_name="$(basename "$recipe_dir")"
  dst_dir="$ISO_SRC_MIRROR_ROOT/$recipe_name/.repro/output/install"
  mkdir -p "$(dirname "$dst_dir")"
  # cp -a preserves symlinks + permissions + timestamps.  We do NOT
  # dereference symlinks (no -L) so internal soname chains stay
  # symlinks rather than balloon into duplicate files.
  cp -a "$install_dir" "$dst_dir"
  staged_recipes=$((staged_recipes + 1))
done
echo "[stage-de-rootfs] staged $staged_recipes from-source install-mirrors"

# ---------------------------------------------------------------------------
# Phase 2: walk every staged ELF's RPATH + PT_INTERP, collect unique
# /nix/store/<hash>-<pkg>/ prefixes, and mirror each one onto the ISO
# verbatim.  This is the closure of nix-stub deps the from-source
# recipes reference via $LD_LIBRARY_PATH-reflected RPATH entries +
# the nix-shell glibc interpreter every nix-built ELF inherits.
# ---------------------------------------------------------------------------

# Discover candidate ELFs (from the staged mirror + the reproos-
# installer + repro CLI binaries we overlay later in this script).
patchelf_bin="$(command -v patchelf || true)"
if [ -z "$patchelf_bin" ]; then
  echo "[stage-de-rootfs] patchelf not in PATH; cannot compute nix-store closure" >&2
  echo "[stage-de-rootfs] expected nix-shell to provision patchelf via the bootstrap-linux-smoke.sh" >&2
  exit 70
fi

# Collect nix-store prefixes from every ELF's RPATH + PT_INTERP.
# Using a temporary file as a poor-man's set; sort -u dedup at end.
nix_prefixes_file="$(mktemp -t reproos-iso-nix-prefixes-XXXXXX)"
trap 'rm -f "$nix_prefixes_file"' EXIT

extract_nix_prefixes_from_elf() {
  local elf="$1"
  local rp interp
  rp="$($patchelf_bin --print-rpath "$elf" 2>/dev/null || true)"
  interp="$($patchelf_bin --print-interpreter "$elf" 2>/dev/null || true)"
  # Split rp on ':' and emit each /nix/store/<hash>-<pkg>/ prefix.
  printf '%s\n' "$rp" | tr ':' '\n' | \
    sed -nE 's|^(/nix/store/[^/]+)(/.*)?$|\1|p'
  printf '%s\n' "$interp" | \
    sed -nE 's|^(/nix/store/[^/]+)(/.*)?$|\1|p'
}
export -f extract_nix_prefixes_from_elf

# Walk the staged source mirror + the reproos-installer + repro CLI.
# The latter two get overlayed later in this script but we need their
# nix-store closure included BEFORE the overlay so the loader resolves
# correctly.
{
  find "$ISO_SRC_MIRROR_ROOT" -type f \
    \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) 2>/dev/null
  if [ -x "$REPO_ROOT/apps/reproos-installer/.repro/output/install/usr/bin/reproos-installer" ]; then
    echo "$REPO_ROOT/apps/reproos-installer/.repro/output/install/usr/bin/reproos-installer"
  fi
  if [ -x "$REPO_ROOT/build/bin/repro" ]; then
    echo "$REPO_ROOT/build/bin/repro"
  fi
} | while IFS= read -r elf; do
  # Cheap ELF-magic check before patchelf invocation.
  magic=$(head -c 4 "$elf" 2>/dev/null | od -An -c | tr -d ' \n' || true)
  case "$magic" in
    177ELF*) extract_nix_prefixes_from_elf "$elf" ;;
  esac
done | sort -u > "$nix_prefixes_file"

nix_closure_count=$(wc -l < "$nix_prefixes_file")
echo "[stage-de-rootfs] discovered $nix_closure_count unique /nix/store/ prefixes"

# Mirror each prefix verbatim.  We dereference symlinks AT the leaf
# level only via cp -a; nix-store contents are themselves symlink-
# heavy so cp -a preserves the topology.  Any single prefix is
# self-contained: nix-store sub-dirs don't link to outside the
# prefix.
mirrored_prefixes=0
while IFS= read -r prefix; do
  [ -z "$prefix" ] && continue
  [ -d "$prefix" ] || continue
  dst="$STAGE_DIR$prefix"
  if [ -e "$dst" ]; then
    # Idempotent: re-running the script should not re-copy.
    continue
  fi
  mkdir -p "$(dirname "$dst")"
  cp -a "$prefix" "$dst"
  mirrored_prefixes=$((mirrored_prefixes + 1))
done < "$nix_prefixes_file"
echo "[stage-de-rootfs] mirrored $mirrored_prefixes nix-store prefixes onto ISO"

# ---------------------------------------------------------------------------
# Phase 3: nix-store closure is one level deep — the prefixes we
# mirrored above themselves have RPATHs that reach OTHER nix-store
# prefixes.  Iterate to fixed point.
# ---------------------------------------------------------------------------

iter=0
while :; do
  iter=$((iter + 1))
  new_prefixes_file="$(mktemp -t reproos-iso-nix-prefixes-it-XXXXXX)"
  # Walk every ELF inside the freshly-mirrored nix-store dirs and
  # collect their RPATH/INTERP references.
  while IFS= read -r prefix; do
    [ -z "$prefix" ] && continue
    staged_prefix="$STAGE_DIR$prefix"
    [ -d "$staged_prefix" ] || continue
    find "$staged_prefix" -type f \
      \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) 2>/dev/null | \
      while IFS= read -r elf; do
        magic=$(head -c 4 "$elf" 2>/dev/null | od -An -c | tr -d ' \n' || true)
        case "$magic" in
          177ELF*) extract_nix_prefixes_from_elf "$elf" ;;
        esac
      done
    # M9.R.29.19 — also walk symlink targets that point into
    # /nix/store. nix's multi-output gcc-lib library ships
    # libgcc_s.so.1 as a symlink into a SEPARATE store path
    # (gcc-X.Y.Z-libgcc), and the loader follows the symlink at
    # dlopen() time. Without this walk the closure missed every
    # gcc-libgcc output and plasmashell + kwin_wayland + sway
    # crashed at startup with 'cannot open shared object file:
    # libgcc_s.so.1'.
    # M9.R.29.19b — use find's -lname predicate to match symlinks
    # whose target is under /nix/store in ONE pass + -printf '%l'
    # to emit the target string directly, avoiding a per-symlink
    # shell fork (breeze-icons alone has 24k+ symlinks).
    find "$staged_prefix" -type l -lname '/nix/store/*' -printf '%l\n' 2>/dev/null | \
      sed -nE 's|^(/nix/store/[^/]+)(/.*)?$|\1|p'
  done < "$nix_prefixes_file" | sort -u > "$new_prefixes_file"

  # Filter out prefixes we already mirrored.
  to_mirror=$(comm -23 "$new_prefixes_file" "$nix_prefixes_file" 2>/dev/null || true)
  if [ -z "$to_mirror" ]; then
    rm -f "$new_prefixes_file"
    break
  fi
  added=0
  while IFS= read -r prefix; do
    [ -z "$prefix" ] && continue
    [ -d "$prefix" ] || continue
    dst="$STAGE_DIR$prefix"
    if [ -e "$dst" ]; then
      continue
    fi
    mkdir -p "$(dirname "$dst")"
    cp -a "$prefix" "$dst"
    added=$((added + 1))
  done <<< "$to_mirror"
  echo "[stage-de-rootfs] iteration $iter: mirrored $added new nix-store prefixes"
  # Union the new prefixes into the working set so the next iteration
  # walks them in turn.
  cat "$nix_prefixes_file" "$new_prefixes_file" | sort -u > "$nix_prefixes_file.next"
  mv "$nix_prefixes_file.next" "$nix_prefixes_file"
  rm -f "$new_prefixes_file"
  if [ "$iter" -ge 10 ]; then
    echo "[stage-de-rootfs] nix-store closure didn't converge in 10 iterations" >&2
    break
  fi
done

# ---------------------------------------------------------------------------
# Phase 4: user-facing entry-point symlinks under /usr/bin and
# /usr/share for the live ISO.  Sessions enumerate them at standard
# paths; SDDM/GDM/sway exec them directly.
# ---------------------------------------------------------------------------

mkdir -p "$STAGE_DIR/usr/bin"
mkdir -p "$STAGE_DIR/usr/share/wayland-sessions"

# Helper to symlink a DE entry-point.  The symlink target is the
# absolute mirrored install-mirror path (which IS the build-host path
# preserved via Phase 1) so it stays valid inside the squashfs root.
link_entry() {
  local recipe="$1"
  local binname="$2"
  local src="$ISO_SRC_MIRROR_ROOT/$recipe/.repro/output/install/usr/bin/$binname"
  # Strip $STAGE_DIR for the link target so the link is absolute
  # WITHIN the rootfs (i.e. resolves correctly after pivot_root).
  local link_target="${src#$STAGE_DIR}"
  if [ ! -e "$src" ]; then
    echo "[stage-de-rootfs] entry-point missing: $recipe/$binname (recipe not built; symlink skipped)" >&2
    return 0
  fi
  ln -sf "$link_target" "$STAGE_DIR/usr/bin/$binname"
}

# DE entry-points.  Each maps to one Wayland-session .desktop file
# below.
link_entry sway sway
link_entry kwin kwin_wayland
link_entry kwin kwin_wayland_wrapper
link_entry mutter mutter
link_entry sddm sddm
link_entry sddm sddm-greeter-qt6
link_entry plasma-workspace plasmashell
link_entry plasma-workspace startplasma-wayland
link_entry plasma-workspace startplasma-x11
link_entry gdm gdm-session-worker
link_entry gdm gdm

# ---------------------------------------------------------------------------
# Phase 4b (M9.R.33.3): base-userspace from-source mirror loop.
#
# The per-recipe Phase 1 mirror already copies every from-source
# install-mirror into the squashfs at the absolute path the build host
# uses (e.g. /opt/repro/reprobuild/recipes/packages/source/systemd/
# .repro/output/install/usr/bin/systemctl).  What's missing is the
# /usr/{bin,sbin}/<name> shadow link so PID 1 / login shell / agetty
# find these binaries via PATH; without it the Debian apt entries in
# build-base-rootfs.sh's PKG_LIST shadow the from-source equivalents
# for ever.
#
# This loop walks every recipe in BASE_USERSPACE_RECIPES and emits an
# absolute /usr/bin or /usr/sbin symlink for every regular file under
# the install-mirror's bin/ + sbin/ subtrees (matching the link_entry
# helper above's pattern).  M9.R.33.4..12 then drop the corresponding
# apt entries from build-base-rootfs.sh's PKG_LIST one commit at a
# time, verified by rebuilding the base-rootfs + confirming the from-
# source binary is the one resolved at PATH lookup time on the staged
# ISO.
#
# The list mirrors the 9 FS:done entries documented in the M9.R.32.4
# audit annotations of build-base-rootfs.sh PKG_LIST (systemd,
# util-linux, kmod, dbus, sudo, e2fsprogs, btrfs-progs, shadow-utils,
# iana-tzdata).  iana-tzdata ships /usr/share/zoneinfo + a small
# /usr/bin tzdata helper; the rest ship pure executables.

BASE_USERSPACE_RECIPES=(
  systemd
  util-linux
  kmod
  dbus
  sudo
  e2fsprogs
  btrfs-progs
  shadow-utils
  iana-tzdata
)

link_base_recipe_binaries() {
  local recipe="$1"
  local install_usr="$ISO_SRC_MIRROR_ROOT/$recipe/.repro/output/install/usr"
  if [ ! -d "$install_usr" ]; then
    echo "[stage-de-rootfs] base-userspace mirror missing: $recipe (recipe not built; skipped)" >&2
    return 0
  fi
  local sub
  local linked=0
  local skipped=0
  for sub in bin sbin; do
    local src_dir="$install_usr/$sub"
    [ -d "$src_dir" ] || continue
    mkdir -p "$STAGE_DIR/usr/$sub"
    local file
    # Walk regular files + symlinks (some recipes ship multi-call
    # binaries as symlinks under bin/; we want the link target's path
    # but the original name).
    for file in "$src_dir"/*; do
      [ -e "$file" ] || continue
      local name
      name="$(basename "$file")"
      # M9.R.33.3 — strip the $STAGE_DIR prefix so the symlink target is
      # absolute WITHIN the rootfs (resolves correctly after pivot_root).
      local link_target="${file#$STAGE_DIR}"
      local dst="$STAGE_DIR/usr/$sub/$name"
      # If the apt-installed binary is already at this path and is NOT
      # the from-source link, the apt entry shadows from-source.  We
      # ALWAYS prefer from-source per the M9.R.33 task brief; force
      # replace the apt-installed copy with the from-source symlink.
      # (The M9.R.33.4..12 follow-up commits remove the matching apt
      # PKG_LIST entries; until then the force-link gives from-source
      # precedence.)
      ln -sf "$link_target" "$dst"
      linked=$((linked + 1))
    done
  done
  # iana-tzdata: also stage /usr/share/zoneinfo from the recipe's
  # install-mirror.  Other base-userspace recipes ship usr/share/
  # files (man pages, locale, ...) that the apt-installed equivalents
  # cover; we don't shadow those at v1 (the data-only files don't
  # affect runtime correctness for the v1 DE smoke surface).  The
  # /usr/share/zoneinfo case is special-cased because date(1) +
  # systemd-timesyncd both probe it at process start.
  if [ "$recipe" = "iana-tzdata" ]; then
    local zoneinfo_src="$install_usr/share/zoneinfo"
    if [ -d "$zoneinfo_src" ]; then
      local zoneinfo_link_target="${zoneinfo_src#$STAGE_DIR}"
      mkdir -p "$STAGE_DIR/usr/share"
      # /usr/share/zoneinfo is a directory in apt-debian; we shadow it
      # with a symlink to the from-source dir.  Replace if present.
      rm -rf "$STAGE_DIR/usr/share/zoneinfo"
      ln -sf "$zoneinfo_link_target" "$STAGE_DIR/usr/share/zoneinfo"
    fi
  fi
  echo "[stage-de-rootfs] base-userspace: $recipe -> $linked /usr/{bin,sbin} shadow links"
}

echo "[stage-de-rootfs] staging base-userspace shadow links"
for base_recipe in "${BASE_USERSPACE_RECIPES[@]}"; do
  link_base_recipe_binaries "$base_recipe"
done

# Stage /etc/wayland-sessions/ session files for SDDM/GDM to enumerate.
cat > "$STAGE_DIR/usr/share/wayland-sessions/sway.desktop" <<EOF
[Desktop Entry]
Name=Sway
Comment=An i3-compatible Wayland compositor
Exec=/usr/bin/sway
Type=Application
DesktopNames=sway
EOF

cat > "$STAGE_DIR/usr/share/wayland-sessions/plasma.desktop" <<EOF
[Desktop Entry]
Name=Plasma (Wayland)
Comment=Plasma by KDE
Exec=/usr/bin/startplasma-wayland
TryExec=/usr/bin/startplasma-wayland
Type=Application
DesktopNames=KDE
EOF

cat > "$STAGE_DIR/usr/share/wayland-sessions/gnome.desktop" <<EOF
[Desktop Entry]
Name=GNOME
Comment=This session logs you into GNOME (Wayland)
Exec=/usr/bin/gnome-session
Type=Application
DesktopNames=GNOME
EOF

# M9.R.18.14 -- ReproOS Installer session.
cat > "$STAGE_DIR/usr/share/wayland-sessions/reproos-installer.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=ReproOS Installer
Comment=First-boot ReproOS installer wizard (kiosk mode)
Exec=/usr/bin/reproos-installer-launcher
DesktopNames=reproos-installer
EOF

# Companion launcher script -- starts a Wayland compositor in kiosk
# mode and execs the installer binary full-screen.
cat > "$STAGE_DIR/usr/bin/reproos-installer-launcher" <<'EOF'
#!/bin/sh
# ReproOS Installer kiosk launcher.

set -eu

INSTALLER_BIN=/usr/bin/reproos-installer
if [ ! -x "$INSTALLER_BIN" ]; then
  exec /usr/bin/startplasma-wayland
fi

# M9.R.36.1 — build a TARGETED LD_LIBRARY_PATH for the installer's
# QProcess children (libclingo / libsqlite3 dlopen via Nim
# {.dynlib: const-string.}).  Skip glibc dirs to avoid shadowing the
# Debian-installed libc.so.6 with a foreign nix-store glibc (which
# would break every Debian binary in the chain).
_repro_nix_dirs=""
# M9.R.37.2 — use a subshell for the glob-existence test so the
# script's positional parameters ($@) are not clobbered.  This GUI
# launcher doesn't pass $@ to the installer (it execs sway, then sway
# execs the installer via SWAY_INIT), but the hygiene fix matches the
# sister-launcher fix in the ``.sh`` variant and prevents future
# regressions.
for d in /nix/store/*/lib; do
  [ -d "$d" ] || continue
  case "$d" in
    /nix/store/*-glibc-*/lib) continue ;;
  esac
  if ! ( set -- "$d"/*.so*; [ -e "$1" ] ); then
    continue
  fi
  if [ -z "$_repro_nix_dirs" ]; then
    _repro_nix_dirs="$d"
  else
    _repro_nix_dirs="$_repro_nix_dirs:$d"
  fi
done
if [ -n "${LD_LIBRARY_PATH:-}" ]; then
  LD_LIBRARY_PATH="$_repro_nix_dirs:$LD_LIBRARY_PATH"
else
  LD_LIBRARY_PATH="$_repro_nix_dirs"
fi
export LD_LIBRARY_PATH

export QT_QPA_PLATFORM=wayland
export QT_QUICK_CONTROLS_STYLE=Material
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export XDG_RUNTIME_DIR
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 700 "$XDG_RUNTIME_DIR"
fi

SWAY_INIT=$(mktemp -t reproos-installer-sway-init-XXXXXX.sh)
cat > "$SWAY_INIT" <<'INIT'
#!/bin/sh
/usr/bin/reproos-installer "$@"
/usr/bin/swaymsg exit
INIT
chmod +x "$SWAY_INIT"

SWAY_CFG=$(mktemp -t reproos-installer-sway-XXXXXX.cfg)
cat > "$SWAY_CFG" <<SWAY
output * background #0a0a0a solid_color
exec $SWAY_INIT
default_border none
font pango:Sans 11
SWAY

exec /usr/bin/sway -c "$SWAY_CFG"
EOF
chmod +x "$STAGE_DIR/usr/bin/reproos-installer-launcher"

# ---------------------------------------------------------------------------
# Phase 5: systemd target wiring (console vs graphical default).
# Unchanged from pre-M9.R.25 behaviour.  REPRO_LIVE_TARGET=console is
# the safe default; graphical opt-in switches to SDDM autologin once
# the from-source DE recipes resolve cleanly on the ISO.
# ---------------------------------------------------------------------------

mkdir -p "$STAGE_DIR/etc/systemd/system"
REPRO_LIVE_TARGET="${REPRO_LIVE_TARGET:-console}"
case "$REPRO_LIVE_TARGET" in
  graphical)
    ln -sf /usr/lib/systemd/system/sddm.service \
      "$STAGE_DIR/etc/systemd/system/display-manager.service"
    ln -sf /usr/lib/systemd/system/graphical.target \
      "$STAGE_DIR/etc/systemd/system/default.target"
    ;;
  console)
    ln -sf /usr/lib/systemd/system/multi-user.target \
      "$STAGE_DIR/etc/systemd/system/default.target"
    ;;
  *)
    echo "[stage-de-rootfs] unknown REPRO_LIVE_TARGET=$REPRO_LIVE_TARGET" >&2
    exit 64
    ;;
esac

# Console-mode autologin override.
mkdir -p "$STAGE_DIR/etc/systemd/system/getty@tty1.service.d"
cat > "$STAGE_DIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud %I 115200,38400,9600 $TERM
EOF

# M9.R.39.2 — installer auto-run unit, gated on the
# ``repro.installer.autorun=1`` kernel cmdline parameter.  Without this
# unit the live-ISO investigation chain depends on the FIFO + login +
# manual ``echo /usr/bin/reproos-installer-launcher.sh ...`` dance, which
# M9.R.39.1 found to wedge in QEMU -nographic mode (serial-getty's
# autologin chain hangs in a terminal-size probe loop on certain hosts).
# The unit runs the launcher BEFORE multi-user.target so it doesn't
# depend on getty / login / bash startup at all.  It boots straight from
# systemd, no FIFO required.
#
# Activation: the GRUB cmdline appends ``repro.installer.autorun=1`` and
# the unit's ``ConditionKernelCommandLine=`` predicate gates the run.
# The companion ``repro.installer.diag=1`` flag flips DIAG mode on so
# the M9.R.39.1 LD_DEBUG=libs + strace + /dev/vdb persistence fires.
#
# The unit's ExecStart includes the FULL pre-installer environment the
# launcher relied on:
#   * QT_QPA_PLATFORM=offscreen (the launcher checks this; without it
#     the binary tries to load the wayland QPA plugin and fails before
#     anything useful happens).
#   * REPRO_INSTALLER_DIAG=1 (DIAG mode -> LD_DEBUG + strace + persist).
#
# After the installer exits (success or SIGABRT), the unit runs
# ``poweroff`` so QEMU shuts down cleanly + the driver's wait completes
# without needing a timeout kill that could interrupt the diag-persist
# dd to /dev/vdb.
mkdir -p "$STAGE_DIR/etc/systemd/system"
cat > "$STAGE_DIR/etc/systemd/system/reproos-installer-autorun.service" <<'EOF'
[Unit]
Description=ReproOS Installer auto-run (M9.R.39.2 diagnostic boot path)
ConditionKernelCommandLine=repro.installer.autorun=1
DefaultDependencies=no
After=local-fs.target sysinit.target
Before=multi-user.target getty.target

[Service]
Type=oneshot
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
Environment=QT_QPA_PLATFORM=offscreen
Environment=REPRO_INSTALLER_DIAG=1
ExecStart=/bin/sh -c 'echo === REPROOS-INSTALLER-AUTORUN-BEGIN ===; /usr/bin/reproos-installer-launcher.sh --automated /etc/reproos/auto-config.toml; echo === REPROOS-INSTALLER-AUTORUN-END RC=$? ==='
# Always poweroff after the run so the host driver can detect end-of-life
# via QEMU exit; even on SIGABRT we want a clean shutdown so the
# /dev/vdb diag dd reaches stable storage.
ExecStopPost=/bin/sh -c 'sync; sync; /sbin/poweroff -f'

[Install]
WantedBy=multi-user.target
EOF

# Enable the unit via a symlink under multi-user.target.wants/ so
# systemd activates it during boot (when the kernel-cmdline condition
# is satisfied).  Without the explicit Wants link the unit is staged
# but never triggered.
mkdir -p "$STAGE_DIR/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/reproos-installer-autorun.service \
  "$STAGE_DIR/etc/systemd/system/multi-user.target.wants/reproos-installer-autorun.service"

# M9.R.36.1 — ``reproos-installer`` wrapper that sets a TARGETED
# LD_LIBRARY_PATH for the installer's QProcess children.  Nim's
# ``{.dynlib: const-string.}`` pragma calls ``dlopen("libclingo.so")``
# with a BARE leaf name from the ``repro`` binary the installer
# spawns; the live ISO bundles libclingo at
# ``/nix/store/<hash>-clingo-*/lib/libclingo.so`` which no default
# ld.so search rule covers.
#
# A naive shell-level LD_LIBRARY_PATH that includes ALL
# ``/nix/store/*/lib`` dirs shadows Debian-installed glibc with a
# foreign nix-store glibc (different ``__nptl_change_stack_perm``
# private-symbol version), which then breaks every Debian binary
# (``cat`` / ``head`` / ``ls`` / ``tail`` all fail with
# ``symbol lookup error``).  So we surgically include ONLY the
# clingo + qt6 + sqlite + nimcrypto-style dirs the ``repro``
# binary's runtime dlopen needs — explicitly skipping any
# ``/nix/store/*-glibc-*/lib`` dir so the Debian binaries keep
# their compatible system glibc.
#
# The wrapper applies the LD_LIBRARY_PATH only inside its own
# ``exec env LD_LIBRARY_PATH=... reproos-installer`` invocation —
# it doesn't leak into the parent shell.
mkdir -p "$STAGE_DIR/usr/bin"
cat > "$STAGE_DIR/usr/bin/reproos-installer-launcher.sh" <<'EOF'
#!/bin/sh
# ReproOS installer wrapper. M9.R.36.1.
#
# Build TARGETED env vars (LD_LIBRARY_PATH + QT_PLUGIN_PATH +
# QML2_IMPORT_PATH + QT_QPA_PLATFORM_PLUGIN_PATH) so the installer
# + its QProcess children find every bundled lib + Qt plugin + QML
# module WITHOUT shadowing the system glibc with a foreign nix-store
# glibc.
#
# Channels:
#   * LD_LIBRARY_PATH       — dlopen("libclingo.so") / libsqlite3
#   * QT_PLUGIN_PATH        — Qt platform / image / sql / styles plugins
#   * QML2_IMPORT_PATH      — QtQuick.Controls + every QML module
#   * QT_QPA_PLATFORM_PLUGIN_PATH — QPA backend (offscreen / wayland /
#                              minimal) — explicit so the
#                              ``QT_QPA_PLATFORM=offscreen`` env var
#                              the installer respects resolves the
#                              ``libqoffscreen.so`` plugin.
_repro_nix_libs=""
_repro_qt_plugins=""
_repro_qml_imports=""
_repro_qpa_plugins=""
# M9.R.37.2 — DO NOT use ``set -- "$d"/*.so*`` to test for the glob
# existence: ``set --`` overwrites the script's positional parameters
# ($@), which is what we ultimately pass to ``reproos-installer``.
# The previous M9.R.36.1 launcher (this script's prior shape) clobbered
# $@ on every loop iteration and ended up exec-ing the installer with
# the LAST nix-store dir's ``*.so*`` glob expansion as its argv —
# silently dropping ``--automated /etc/reproos/auto-config.toml``,
# so the installer fell into GUI mode + QML engine init + endless
# dlopen() churn through LD_LIBRARY_PATH (the M9.R.36 "silent wedge
# after Qt init").  Use a subshell's exit code instead: if the first
# entry of the expansion exists, the subshell succeeds; otherwise it
# fails.  $@ is untouched.
#
# M9.R.37.5 — be SURGICAL about which dirs go on LD_LIBRARY_PATH.  The
# previous wholesale ``/nix/store/*/lib`` walk added ~600 dirs to
# LD_LIBRARY_PATH; every dlopen() inside the installer's QProcess
# children then had to iterate all 600 before falling through to
# ld.so.cache.  The DT_NEEDED libs the ``repro`` binary uses at
# runtime (libclingo / libsqlite3) are well-known leaf names hit via
# Nim's ``{.dynlib: const-string.}`` pragma, so we only need their
# specific dirs on LD_LIBRARY_PATH.  Every OTHER library the binaries
# need is already resolvable via either embedded RPATH or ld.so.cache
# (M9.R.37.3 + M9.R.37.4 made the cache reachable from every PT_INTERP).
#
# This dramatically narrows LD_LIBRARY_PATH from ~600 entries to
# a handful, slashing each dlopen()'s syscall cost from ~600 ENOENT
# probes to ~5.
for d in /nix/store/*/lib; do
  [ -d "$d" ] || continue
  # Skip glibc dirs — Debian system glibc must remain canonical so
  # every Debian binary in the live ISO chain keeps working.
  case "$d" in
    /nix/store/*-glibc-*/lib) continue ;;
  esac
  # M9.R.38.3 — skip ANY nix-store Qt6 prefix.  The installer is
  # compiled + RPATH'd against ``/opt/repro/.../qt6-base/.repro/
  # output/install/usr/lib/libQt6Core.so.6.8.1``, but the de-rootfs
  # mirror also ships an UNRELATED ``zp6r9bxds...-qtbase-6.10.1/lib/``
  # tree pulled in as a transitive of layer-shell-qt-6.5.3 (which is
  # in the DE closure).  Without this skip the launcher's qt-6/plugins
  # / qt-6/qml walk below picks up the 6.10.1 plugin tree as well, and
  # the Qt 6.8.1 binary loading a 6.10.1 ``libqoffscreen.so`` /
  # ``QtQuick.Controls`` plugin trips C++ ABI mismatch -> heap
  # corruption -> ``munmap_chunk(): invalid pointer`` on init, SIGABRT
  # before Phase 1.  The qt6-base + qt6-declarative + qt6-quickcontrols2
  # the installer needs live at /opt/repro/... paths the RPATH already
  # covers; no nix-store Qt6 mirror is required.
  case "$d" in
    /nix/store/*-qtbase-*/lib | \
    /nix/store/*-qtdeclarative-*/lib | \
    /nix/store/*-qt5compat-*/lib | \
    /nix/store/*-layer-shell-qt-*/lib | \
    /nix/store/*-kquickcharts-*/lib | \
    /nix/store/*-qtquickcontrols*/lib | \
    /nix/store/*-qttools-*/lib | \
    /nix/store/*-qtwayland-*/lib) continue ;;
  esac
  # M9.R.37.5: include ONLY dirs that ship a library the ``repro``
  # binary's Nim {.dynlib: "..."} pragma resolves by bare leaf name:
  #   * libclingo.so      (libs/repro_solver/.../clingo_bindings.nim)
  #   * libsqlite3.so(.0) (libs/repro_local_store/.../sqlite3_binding.nim)
  # plus any sqlite3 successor name (the bindings tries _64 / _32
  # variants on Windows only; libsqlite3.so covers POSIX).
  if [ -e "$d/libclingo.so" ] || [ -e "$d/libsqlite3.so" ] || \
     [ -e "$d/libsqlite3.so.0" ]; then
    if [ -z "$_repro_nix_libs" ]; then
      _repro_nix_libs="$d"
    else
      _repro_nix_libs="$_repro_nix_libs:$d"
    fi
  fi
  # Qt6 plugin dirs ship under ``<prefix>/lib/qt-6/plugins/``.
  if [ -d "$d/qt-6/plugins" ]; then
    if [ -z "$_repro_qt_plugins" ]; then
      _repro_qt_plugins="$d/qt-6/plugins"
    else
      _repro_qt_plugins="$_repro_qt_plugins:$d/qt-6/plugins"
    fi
    if [ -d "$d/qt-6/plugins/platforms" ]; then
      if [ -z "$_repro_qpa_plugins" ]; then
        _repro_qpa_plugins="$d/qt-6/plugins/platforms"
      else
        _repro_qpa_plugins="$_repro_qpa_plugins:$d/qt-6/plugins/platforms"
      fi
    fi
  fi
  # Qt6 QML modules ship under ``<prefix>/lib/qt-6/qml/``.
  if [ -d "$d/qt-6/qml" ]; then
    if [ -z "$_repro_qml_imports" ]; then
      _repro_qml_imports="$d/qt-6/qml"
    else
      _repro_qml_imports="$_repro_qml_imports:$d/qt-6/qml"
    fi
  fi
done
# M9.R.38.3 — the installer's RPATH points to /opt/repro/.../qt6-base
# /.repro/output/install/usr/lib/qt-6/plugins/ + qt6-declarative's
# qt-6/qml/.  Wire those EXPLICITLY since the loop above only walks
# /nix/store; without this Qt finds no plugins + falls back to system
# Debian Qt6 (which doesn't exist in the live DE rootfs) + crashes on
# QtQuick init.
for repro_qt_pkg in qt6-base qt6-declarative qt6-quickcontrols2 qt6-tools; do
  qtpkg_dir="/opt/repro/reprobuild/recipes/packages/source/${repro_qt_pkg}/.repro/output/install/usr/lib"
  if [ -d "${qtpkg_dir}/qt-6/plugins" ]; then
    _repro_qt_plugins="${qtpkg_dir}/qt-6/plugins${_repro_qt_plugins:+:$_repro_qt_plugins}"
    if [ -d "${qtpkg_dir}/qt-6/plugins/platforms" ]; then
      _repro_qpa_plugins="${qtpkg_dir}/qt-6/plugins/platforms${_repro_qpa_plugins:+:$_repro_qpa_plugins}"
    fi
  fi
  if [ -d "${qtpkg_dir}/qt-6/qml" ]; then
    _repro_qml_imports="${qtpkg_dir}/qt-6/qml${_repro_qml_imports:+:$_repro_qml_imports}"
  fi
done
# Append caller-supplied paths last so any operator override wins.
if [ -n "${LD_LIBRARY_PATH:-}" ]; then
  _repro_ldpath="$_repro_nix_libs:$LD_LIBRARY_PATH"
else
  _repro_ldpath="$_repro_nix_libs"
fi

# M9.R.37.1 / M9.R.39.1 — diagnostic mode.  When ``REPRO_INSTALLER_DIAG=1``
# is set, the launcher:
#   (a) wraps the installer process in ``strace -f -ttt -o
#       /tmp/installer.strace`` so we capture every syscall on every
#       thread with microsecond timestamps;
#   (b) forces stderr line-buffering via ``stdbuf -oL -eL`` so the
#       installer's ``appendLog`` ``QTextStream(stderr)`` writes
#       reach the pipe BEFORE any wedge stalls subsequent buffer
#       flushes;
#   (c) starts a side-thread that snapshots the installer's
#       ``/proc/<pid>/status``, ``/proc/<pid>/stack``,
#       ``/proc/<pid>/wchan`` + every TID under
#       ``/proc/<pid>/task/`` every 5 seconds into
#       ``/tmp/installer.kernelstacks``;
#   (d) M9.R.39.1 — exports ``LD_DEBUG=libs`` so glibc's loader dumps
#       every shared-lib resolution decision (DT_NEEDED -> path, RPATH
#       walk, ld.so.cache fall-through, version-mismatch warnings) to
#       a file we can read post-crash.  This is the canonical channel
#       for identifying ABI / version mismatches between the installer
#       binary's expected libs and what the live ISO presents.
#   (e) M9.R.39.1 — on installer exit (success OR SIGABRT), persists
#       /tmp/installer.{strace,kernelstacks,log,lddebug} onto the
#       second virtio disk (/dev/vdb) which the driver attaches.
#       Without this, the M9.R.37/38 tmpfs logs vanish on poweroff.
#       We format /dev/vdb as ext4 if it's blank, mount it at /mnt/diag,
#       cp the logs in, sync, then return the installer's exit code.
#       The driver post-mortem extracts the logs from the qcow2.
#
# This diagnostic apparatus is the M9.R.37 wedge characterisation
# infrastructure the M9.R.36 closeout flagged as a follow-up, plus
# the M9.R.39 LD_DEBUG + log-persistence extension the M9.R.38
# closeout flagged as the next investigation step.
_repro_diag="${REPRO_INSTALLER_DIAG:-0}"
if [ "$_repro_diag" = "1" ]; then
  rm -f /tmp/installer.strace /tmp/installer.kernelstacks \
        /tmp/installer.lddebug /tmp/installer.log /tmp/installer.diag.pid
  # Launch the kernel-stack snapshotter as a background sub-shell.
  # The installer's PID becomes its parent shell's $$ once exec
  # replaces this script, so we sample $$ from the child's POV via
  # a marker file: write our own PID to /tmp/installer.diag.pid AFTER
  # we fork the installer.
  (
    n=0
    while [ ! -f /tmp/installer.diag.pid ] && [ $n -lt 20 ]; do
      sleep 0.5
      n=$((n+1))
    done
    [ -f /tmp/installer.diag.pid ] || exit 0
    INSTPID="$(cat /tmp/installer.diag.pid 2>/dev/null)"
    [ -n "$INSTPID" ] || exit 0
    while kill -0 "$INSTPID" 2>/dev/null; do
      ts="$(date -u '+%Y-%m-%d %H:%M:%S.%N')"
      {
        echo "=== $ts pid=$INSTPID ==="
        echo "--- /proc/$INSTPID/status ---"
        head -8 "/proc/$INSTPID/status" 2>/dev/null
        echo "--- /proc/$INSTPID/wchan ---"
        cat "/proc/$INSTPID/wchan" 2>/dev/null
        echo ""
        echo "--- /proc/$INSTPID/stack ---"
        cat "/proc/$INSTPID/stack" 2>/dev/null
        echo "--- per-tid wchan / stack ---"
        for t in /proc/$INSTPID/task/*; do
          [ -d "$t" ] || continue
          tid="${t##*/}"
          comm="$(cat $t/comm 2>/dev/null)"
          wch="$(cat $t/wchan 2>/dev/null)"
          echo "tid=$tid comm=$comm wchan=$wch"
          head -10 "$t/stack" 2>/dev/null | sed 's/^/  /'
        done
        echo ""
      } >> /tmp/installer.kernelstacks 2>/dev/null
      sleep 5
    done
  ) &
  # M9.R.39.1 — capture a snapshot of the installer binary's
  # DT_NEEDED + RPATH + INTERP so the post-mortem can correlate against
  # the LD_DEBUG=libs trace.
  {
    echo "=== installer binary inventory ==="
    /usr/bin/stat /usr/bin/reproos-installer 2>&1 || true
    /usr/bin/sha256sum /usr/bin/reproos-installer 2>&1 || true
    if command -v patchelf >/dev/null 2>&1; then
      echo "--- patchelf --print-interpreter ---"
      patchelf --print-interpreter /usr/bin/reproos-installer 2>&1
      echo "--- patchelf --print-rpath ---"
      patchelf --print-rpath /usr/bin/reproos-installer 2>&1
      echo "--- patchelf --print-needed ---"
      patchelf --print-needed /usr/bin/reproos-installer 2>&1
    elif command -v readelf >/dev/null 2>&1; then
      echo "--- readelf -d (dynamic section) ---"
      readelf -d /usr/bin/reproos-installer 2>&1 | \
        grep -E 'NEEDED|RUNPATH|RPATH|INTERP' || true
    else
      echo "patchelf + readelf both unavailable"
    fi
    echo "--- ldd (resolution view) ---"
    ldd /usr/bin/reproos-installer 2>&1 | head -60 || true
    echo "=== launcher env ==="
    echo "LD_LIBRARY_PATH=$_repro_ldpath"
    echo "QT_PLUGIN_PATH=$_repro_qt_plugins"
    echo "QML2_IMPORT_PATH=$_repro_qml_imports"
    echo "QT_QPA_PLATFORM_PLUGIN_PATH=$_repro_qpa_plugins"
    echo "=== /etc/ld.so.cache (head) ==="
    if command -v ldconfig >/dev/null 2>&1; then
      ldconfig -p 2>&1 | grep -E 'libstdc\+\+|libgcc_s|libc\.so|libQt6Core|libQt6Gui|libQt6Qml' | head -40
    fi
    echo ""
  } > /tmp/installer.binfo 2>&1
  # Run the installer SYNCHRONOUSLY (not via exec) so we can persist
  # the diagnostic logs to the scratch disk BEFORE poweroff regardless
  # of whether the binary exits cleanly, aborts, or wedges (in which
  # case the driver's timeout kills us and we still drop logs first).
  # ``LD_DEBUG=libs`` makes glibc's loader dump every library lookup
  # decision to stderr; we redirect that to /tmp/installer.lddebug
  # via ``LD_DEBUG_OUTPUT`` so it doesn't interleave with the
  # installer's QTextStream(stderr) writes.
  (
    env \
      LD_LIBRARY_PATH="$_repro_ldpath" \
      LD_DEBUG=libs \
      LD_DEBUG_OUTPUT=/tmp/installer.lddebug \
      QT_PLUGIN_PATH="${QT_PLUGIN_PATH:-}${QT_PLUGIN_PATH:+:}$_repro_qt_plugins" \
      QML2_IMPORT_PATH="${QML2_IMPORT_PATH:-}${QML2_IMPORT_PATH:+:}$_repro_qml_imports" \
      QML_IMPORT_PATH="${QML_IMPORT_PATH:-}${QML_IMPORT_PATH:+:}$_repro_qml_imports" \
      QT_QPA_PLATFORM_PLUGIN_PATH="${QT_QPA_PLATFORM_PLUGIN_PATH:-}${QT_QPA_PLATFORM_PLUGIN_PATH:+:}$_repro_qpa_plugins" \
      strace -f -ttt -y -s 256 -e signal='!SIGCHLD' \
        -o /tmp/installer.strace \
        stdbuf -oL -eL \
        /usr/bin/reproos-installer "$@" \
          > /tmp/installer.log 2>&1
    echo $? > /tmp/installer.rc
  ) &
  _instpid=$!
  echo $_instpid > /tmp/installer.diag.pid
  wait $_instpid
  _rc="$(cat /tmp/installer.rc 2>/dev/null || echo 255)"
  # M9.R.39.1 — persist diag logs to /dev/vdb (the driver attaches a
  # scratch virtio disk for this purpose).  Raw layout for the host
  # extractor (host has gzip + tail, the live ISO has tar + dd):
  #   sector 0 (512 bytes): ASCII header 'M9R39DIAGv1 SIZE=<bytes>\n'
  #                          padded to 512 with spaces; nul-terminated
  #   sector 1+ (4096+):     gzipped tar of /tmp/installer.* files
  if [ -b /dev/vdb ]; then
    _diagtar=/tmp/installer.diag.tar.gz
    tar -czf "$_diagtar" -C /tmp \
      installer.strace installer.kernelstacks installer.lddebug \
      installer.log installer.binfo installer.rc installer.diag.pid \
      2>/dev/null || true
    _diagsz="$(stat -c %s "$_diagtar" 2>/dev/null || echo 0)"
    # ASCII-only header for portability.  The host extractor parses
    # SIZE=<decimal> + skips one 512-byte sector + reads SIZE bytes.
    printf 'M9R39DIAGv1 SIZE=%d\n' "$_diagsz" \
      | dd of=/tmp/installer.diag.header bs=512 count=1 conv=sync 2>/dev/null
    dd if=/tmp/installer.diag.header of=/dev/vdb bs=512 count=1 \
      conv=notrunc 2>/dev/null || true
    dd if="$_diagtar" of=/dev/vdb bs=512 seek=1 conv=notrunc 2>/dev/null || true
    sync
    sync
  fi
  exit "$_rc"
fi

exec env \
  LD_LIBRARY_PATH="$_repro_ldpath" \
  QT_PLUGIN_PATH="${QT_PLUGIN_PATH:-}${QT_PLUGIN_PATH:+:}$_repro_qt_plugins" \
  QML2_IMPORT_PATH="${QML2_IMPORT_PATH:-}${QML2_IMPORT_PATH:+:}$_repro_qml_imports" \
  QML_IMPORT_PATH="${QML_IMPORT_PATH:-}${QML_IMPORT_PATH:+:}$_repro_qml_imports" \
  QT_QPA_PLATFORM_PLUGIN_PATH="${QT_QPA_PLATFORM_PLUGIN_PATH:-}${QT_QPA_PLATFORM_PLUGIN_PATH:+:}$_repro_qpa_plugins" \
  /usr/bin/reproos-installer "$@"
EOF
chmod 0755 "$STAGE_DIR/usr/bin/reproos-installer-launcher.sh"

# Profile hook to auto-launch the installer on root login (tty1 only).
cat > "$STAGE_DIR/etc/profile.d/zz-reproos-installer-autostart.sh" <<'EOF'
# ReproOS live-ISO console-mode installer autostart.
if [ "$(tty)" = "/dev/tty1" ] && [ -z "${REPRO_INSTALLER_RAN:-}" ]; then
  export REPRO_INSTALLER_RAN=1
  AUTO_CFG=""
  for cand in /etc/reproos/auto-config.toml /run/reproos/auto-config.toml; do
    if [ -f "$cand" ]; then
      AUTO_CFG="$cand"
      break
    fi
  done
  if [ -x /usr/bin/reproos-installer ] && [ -n "$AUTO_CFG" ]; then
    echo ""
    echo "=== ReproOS Installer (automated) starting in 3 seconds; Ctrl+C aborts. ==="
    echo "Config: $AUTO_CFG"
    echo ""
    sleep 3
    # M9.R.36.1 — invoke through the launcher wrapper so the
    # installer's QProcess children get the LD_LIBRARY_PATH the
    # ``repro`` binary needs for libclingo / libsqlite3 dlopen.
    QT_QPA_PLATFORM=offscreen \
      /usr/bin/reproos-installer-launcher.sh --automated "$AUTO_CFG"
    rc=$?
    echo ""
    echo "=== Installer exited with rc=$rc ==="
    echo "Type \`poweroff\` to shut down or \`reboot\` to boot into the installed system."
    echo ""
  elif [ -x /usr/bin/reproos-installer ]; then
    echo ""
    echo "=== ReproOS Installer console ==="
    echo "No automated config found at /etc/reproos/auto-config.toml."
    echo "Run \`reproos-installer --help\` to see options, or drop a config"
    echo "TOML at /etc/reproos/auto-config.toml and re-login to run the"
    echo "automated path."
    echo ""
  fi
fi
EOF
chmod 0644 "$STAGE_DIR/etc/profile.d/zz-reproos-installer-autostart.sh"

# Bake a default automated config for the demo run.
mkdir -p "$STAGE_DIR/etc/reproos"
cat > "$STAGE_DIR/etc/reproos/auto-config.toml" <<'EOF'
hostname = "reproos-vm"
defaultUser = "alice"
password = "reproos"
diskoPreset = "simple"
targetDevice = "/dev/vda"
preferredDE = "plasma"
activities = ["daily-computing", "system-tools"]
EOF

# M9.R.18.1 -- SDDM autologin config.
REPRO_AUTOLOGIN_SESSION="${REPRO_AUTOLOGIN_SESSION:-reproos-installer}"
mkdir -p "$STAGE_DIR/etc/sddm.conf.d"
cat > "$STAGE_DIR/etc/sddm.conf.d/00-autologin.conf" <<EOF
[Autologin]
User=live
Session=${REPRO_AUTOLOGIN_SESSION}
Relogin=true

[General]
HaltCommand=/usr/bin/systemctl poweroff
RebootCommand=/usr/bin/systemctl reboot
EOF

# M9.R.24.1 -- Live-ISO debug tap (env-gated).
REPRO_LIVE_DEBUG="${REPRO_LIVE_DEBUG:-0}"
if [ "$REPRO_LIVE_DEBUG" = "1" ]; then
  mkdir -p "$STAGE_DIR/etc/systemd/system"
  cat > "$STAGE_DIR/etc/systemd/system/repro-debug-tap.service" <<'EOF'
[Unit]
Description=ReproOS live-ISO debug journal tap to /dev/ttyS1
After=multi-user.target
Wants=multi-user.target

[Service]
Type=simple
ExecStart=/bin/sh -c '/usr/bin/journalctl -f -o short-monotonic --no-pager > /dev/ttyS1 2>&1'
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
  mkdir -p "$STAGE_DIR/etc/systemd/system/multi-user.target.wants"
  ln -sf /etc/systemd/system/repro-debug-tap.service \
    "$STAGE_DIR/etc/systemd/system/multi-user.target.wants/repro-debug-tap.service"
  echo "[stage-de-rootfs] REPRO_LIVE_DEBUG=1; tap enabled at ttyS1"
fi

# ---------------------------------------------------------------------------
# Phase 6: reproos-installer + repro CLI binary overlay.  The
# nix-store closure these depend on was already mirrored in Phases 2/3
# so the binaries' embedded RPATHs resolve unchanged.
# ---------------------------------------------------------------------------

REPROOS_INSTALLER_BIN="${REPROOS_INSTALLER_BIN:-}"
if [ -z "$REPROOS_INSTALLER_BIN" ]; then
  REPROOS_INSTALLER_BIN="$REPO_ROOT/apps/reproos-installer/.repro/output/install/usr/bin/reproos-installer"
fi
if [ ! -x "$REPROOS_INSTALLER_BIN" ]; then
  echo "[stage-de-rootfs] reproos-installer binary missing or not executable at $REPROOS_INSTALLER_BIN" >&2
  echo "[stage-de-rootfs] build the recipe first: \`repro build apps/reproos-installer --tool-provisioning=from-source\`" >&2
  exit 66
fi
mkdir -p "$STAGE_DIR/usr/bin"
cp "$REPROOS_INSTALLER_BIN" "$STAGE_DIR/usr/bin/reproos-installer"
chmod +x "$STAGE_DIR/usr/bin/reproos-installer"
echo "[stage-de-rootfs] overlayed reproos-installer binary (bytes=$(stat -c %s "$STAGE_DIR/usr/bin/reproos-installer"))"

REPRO_CLI_BIN="${REPRO_CLI_BIN:-}"
if [ -z "$REPRO_CLI_BIN" ]; then
  REPRO_CLI_BIN="$REPO_ROOT/build/bin/repro"
fi
if [ ! -x "$REPRO_CLI_BIN" ]; then
  echo "[stage-de-rootfs] repro CLI binary missing or not executable at $REPRO_CLI_BIN" >&2
  echo "[stage-de-rootfs] build it first: \`just build\` or run the bootstrap script" >&2
  exit 67
fi
cp "$REPRO_CLI_BIN" "$STAGE_DIR/usr/bin/repro"
chmod +x "$STAGE_DIR/usr/bin/repro"
echo "[stage-de-rootfs] overlayed repro CLI (bytes=$(stat -c %s "$STAGE_DIR/usr/bin/repro"))"

# ---------------------------------------------------------------------------
# Phase 7: rebuild ld.so.cache so dlopen(bare-name) calls inside DE
# binaries find shared libs that aren't reachable via embedded RPATH.
# We feed every nix-store-mirrored /lib dir + every from-source
# install-mirror /lib + /lib64 into /etc/ld.so.conf.d/ and let
# /sbin/ldconfig under chroot do the rest.
# ---------------------------------------------------------------------------

mkdir -p "$STAGE_DIR/etc/ld.so.conf.d"
{
  # From-source install-mirror lib dirs.
  for d in "$ISO_SRC_MIRROR_ROOT"/*/.repro/output/install/usr/lib \
           "$ISO_SRC_MIRROR_ROOT"/*/.repro/output/install/usr/lib64; do
    if [ -d "$d" ]; then
      echo "${d#$STAGE_DIR}"
    fi
  done
  # M9.R.27.1 — REMOVED the from-source install-mirror INTERNAL subdir
  # scan (mutter-15/, qt6/plugins/, etc.).  The M9.R.26.5 DSL fix to
  # `m9r14fEmitRpathPatchScript` bakes every internal versioned subdir
  # into the per-recipe RPATH at install-mirror time, and the M9.R.27.1
  # mutter rebuild proved end-to-end that the rebuilt mutter's
  # libmutter-15.so.0 + the internal mutter-15/libmutter-*-15.so libs
  # all carry the right RPATH entry.  No more ld.so.conf fall-through
  # needed — pure embedded RPATH does the job.
  # Nix-store mirrored /lib dirs.
  for d in "$STAGE_DIR"/nix/store/*/lib; do
    if [ -d "$d" ]; then
      echo "${d#$STAGE_DIR}"
    fi
  done
  # Standard fallbacks for the slim Debian base.
  echo "/usr/lib"
  echo "/usr/lib64"
} > "$STAGE_DIR/etc/ld.so.conf.d/zz-reproos-overlay.conf"

# M9.R.37.4 — symlink every nix-store glibc's hard-coded
# ``etc/ld.so.cache`` path to ``/etc/ld.so.cache`` so the
# from-source-built binaries' nix-store PT_INTERPs find the cache the
# Debian system loader writes.  Without this, every binary with PT_INTERP
# ``/nix/store/<hash>-glibc-X.Y/lib/ld-linux-x86-64.so.2`` reads
# ``/nix/store/<hash>-glibc-X.Y/etc/ld.so.cache`` (the path is baked into
# ld-linux at compile time -- ``strings`` it to confirm) which doesn't
# exist on our stage, and the dlopen() fall-through to ld.so.cache
# fails.  Concretely: ``mkfs.ext4`` failed at exec-time with
# ``libext2fs.so.2: cannot open shared object file`` because its PT_INTERP
# pointed at the ``xx7cm72...-glibc-2.40-66`` ld-linux which reads
# ``/nix/store/xx7cm72.../etc/ld.so.cache`` (ENOENT), bypassing the
# Debian system cache at ``/etc/ld.so.cache``.
#
# Fix: for each nix-store glibc dir on the stage, ``chmod u+w`` its
# ``etc/`` subdir then drop a relative symlink at
# ``etc/ld.so.cache -> /etc/ld.so.cache``.  Now every loader -- nix
# or Debian -- reads the SAME cache the system ldconfig wrote.
for glibc_etc in "$STAGE_DIR"/nix/store/*-glibc-*/etc; do
  [ -d "$glibc_etc" ] || continue
  glibc_dir="$(dirname "$glibc_etc")"
  chmod u+w "$glibc_etc" 2>/dev/null || true
  if [ -e "$glibc_etc/ld.so.cache" ] && [ ! -L "$glibc_etc/ld.so.cache" ]; then
    rm -f "$glibc_etc/ld.so.cache"
  fi
  if [ ! -L "$glibc_etc/ld.so.cache" ]; then
    ln -s /etc/ld.so.cache "$glibc_etc/ld.so.cache"
  fi
  echo "[stage-de-rootfs] linked $glibc_etc/ld.so.cache -> /etc/ld.so.cache"
done

chroot_ldconfig="$STAGE_DIR/sbin/ldconfig"
if [ -x "$chroot_ldconfig" ]; then
  # M9.R.37.3 — ``chroot $STAGE_DIR /sbin/ldconfig`` requires root
  # privilege (Linux's mount-namespace barrier).  The engine runs the
  # ISO build as the invoking user, NOT root, so the chroot syscall
  # returned EPERM, ldconfig never ran, and ld.so.cache was either
  # absent (causing every bare-name dlopen to fall through to the
  # Debian system cache) or left at the 16027-byte base-rootfs.tar.xz
  # fossil (which Knew NOTHING about the from-source install-mirrors).
  # Concretely: ``mkfs.ext4`` shipped via ``e2fsprogs/.repro/output/
  # install/usr/sbin/mkfs.ext4`` failed at runtime with exit 127
  # because its DT_NEEDED libs (libext2fs.so.2, libcom_err.so.2,
  # libe2p.so.2) were ABSENT from /etc/ld.so.cache, and the binary's
  # own DT_RUNPATH did NOT include its sister-lib dir.  ``repro disk
  # apply`` consequently failed at Phase 2 / step mkfs.ext4 with
  # ``mkfs.ext4 failed (exit 127)``, which surfaced to the M9.R.36
  # investigation as a "silent installer wedge after Qt init".
  #
  # ``ldconfig -r <root>`` does what chroot+ldconfig does but WITHOUT
  # requiring chroot privilege — it pretends ``<root>`` is "/" for
  # all path resolution + writes the cache at ``<root>/etc/ld.so.cache``.
  # This is the canonical unprivileged-build replacement Debian's
  # debootstrap + Arch's pacstrap both use.
  "$chroot_ldconfig" -r "$STAGE_DIR" 2>&1 | \
    grep -vE 'is not a symbolic link|file format not recognized' || true
  echo "[stage-de-rootfs] rebuilt ld.so.cache via /sbin/ldconfig -r $STAGE_DIR (size: $(stat -c %s "$STAGE_DIR/etc/ld.so.cache" 2>/dev/null || echo missing))"
else
  echo "[stage-de-rootfs] no $chroot_ldconfig; dlopen() bare-name libs may fail" >&2
fi

echo "[stage-de-rootfs] stage-dir bytes=$(du -sb "$STAGE_DIR" | awk '{print $1}')"

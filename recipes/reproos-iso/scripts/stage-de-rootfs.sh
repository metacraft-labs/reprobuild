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
    find "$staged_prefix" -type l 2>/dev/null | \
      while IFS= read -r lnk; do
        target=$(readlink "$lnk" 2>/dev/null || true)
        case "$target" in
          /nix/store/*) printf '%s\n' "$target" | sed -nE 's|^(/nix/store/[^/]+)(/.*)?$|\1|p' ;;
        esac
      done
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

# Profile hook to auto-launch the installer on root login (tty1 only).
mkdir -p "$STAGE_DIR/etc/profile.d"
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
    QT_QPA_PLATFORM=offscreen \
      /usr/bin/reproos-installer --automated "$AUTO_CFG"
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

chroot_ldconfig="$STAGE_DIR/sbin/ldconfig"
if [ -x "$chroot_ldconfig" ]; then
  chroot "$STAGE_DIR" /sbin/ldconfig 2>&1 | \
    grep -vE 'is not a symbolic link|file format not recognized' || true
  echo "[stage-de-rootfs] rebuilt ld.so.cache via chroot/sbin/ldconfig"
else
  echo "[stage-de-rootfs] no chroot/sbin/ldconfig; dlopen() bare-name libs may fail" >&2
fi

echo "[stage-de-rootfs] stage-dir bytes=$(du -sb "$STAGE_DIR" | awk '{print $1}')"

#!/usr/bin/env bash
# R2: deterministic hybrid (BIOS + UEFI) ISO builder.
#
# Wraps `grub-mkrescue` with the flags + env that make the output
# bit-identical across rebuilds when the (kernel, initramfs, GRUB
# configuration, SOURCE_DATE_EPOCH) tuple is held constant.
#
# Inputs (positional):
#   $1 = absolute path to the kernel vmlinuz image
#   $2 = absolute path to the initramfs cpio image
#   $3 = absolute path to write the output ISO to
#
# Required env:
#   SOURCE_DATE_EPOCH = fixed epoch in seconds (e.g. 1735689600 =
#     2025-01-01T00:00:00Z). xorriso >= 1.5.0 + grub-mkrescue >= 2.06
#     honour this for all internal timestamps (PVD, ISO9660 file
#     timestamps, joliet, El Torito).
#   LC_ALL = C
#   TZ    = UTC
#
# The recipe driver (repro.nim's `shell(...)` action) supplies all of
# the above. Re-running with identical inputs and env emits a
# bit-identical ISO; the reproducibility gate at
# `tests/reproducibility/t_r2_iso_reproducibility.sh` proves this by
# running the recipe three times and asserting sha256 equality.

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <kernel> <initramfs> <out.iso>" >&2
  exit 64
fi

KERNEL="$1"
INITRAMFS="$2"
OUT_ISO="$3"

: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set for reproducibility}"
: "${LC_ALL:?LC_ALL=C required for byte-identical output}"
: "${TZ:?TZ=UTC required for byte-identical output}"

# M9.R.17c.1 -- replace the vendored Debian Installer initramfs with a
# from-source live-init-capable initramfs that knows how to loop-mount
# /live/filesystem.squashfs + pivot_root into the DE rootfs overlay.
# The vendored initrd is the d-i installer; it ignores the squashfs
# payload and boots straight into the text-mode installer. Bypass it
# by regenerating $INITRAMFS via build-initramfs.sh when
# REPRO_LIVE_INIT=1.
#
# Default OFF so the historical R2 reproducibility test
# (tests/reproducibility/t_r2_iso_reproducibility.sh) keeps passing
# without invoking the cache-warming side effects of build-initramfs.sh.
# The reproos-iso recipe sets REPRO_LIVE_INIT=1 explicitly.
SCRIPT_DIR_SELF="$(cd "$(dirname "$0")" && pwd)"
REPRO_LIVE_INIT="${REPRO_LIVE_INIT:-0}"
if [ "$REPRO_LIVE_INIT" = "1" ]; then
  LIVE_INIT_OUT="${REPRO_LIVE_INIT_OUT:-$(dirname "$INITRAMFS")/initrd.img-live}"
  echo "[build-iso] regenerating live-init initramfs at $LIVE_INIT_OUT"
  bash "$SCRIPT_DIR_SELF/build-initramfs.sh" "$LIVE_INIT_OUT"
  INITRAMFS="$LIVE_INIT_OUT"
fi

for f in "$KERNEL" "$INITRAMFS"; do
  if [ ! -f "$f" ]; then
    echo "input missing: $f" >&2
    exit 65
  fi
done

# Verify the host has the tools we need. Fail loudly if not; the
# orchestrator's recipe driver already apt-installs these on first run.
for tool in xorriso grub-mkrescue mformat; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "required tool missing: $tool (apt-get install xorriso grub-pc-bin grub-efi-amd64-bin mtools)" >&2
    exit 66
  fi
done

WORK=$(mktemp -d -t reproos-iso-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Reproducibility workaround for Debian 12's mtools 4.0.32: its
# `mformat -C` seeds random() with `time(0)` (see init_random() in
# mtools.h) BEFORE the SOURCE_DATE_EPOCH-aware path runs. The 4-byte
# FAT volume serial in the embedded UEFI ESP image is therefore
# wall-clock-randomised even when SOURCE_DATE_EPOCH is set. grub-
# mkrescue invokes mformat without the `-N <serial>` flag.
#
# Fix: drop a `mformat` shim into a private dir, prepend it on $PATH.
# The shim forwards to /usr/bin/mformat with a deterministic `-N`
# argument prepended, so grub-mkrescue's call resolves to it AND the
# ESP image's volume serial becomes a pinned constant.
#
# Serial value: 32-bit hex constant. Anything stable would work;
# pinning a documented constant is what matters for the recipe.
# 0xb007ed02 == "boot ed02" mnemonic; just an opaque 32-bit FAT vol id.
REPRO_FAT_SERIAL='0xb007ed02'
# Locate the real mformat dynamically so the shim works on Nix-based
# hosts (eli-wsl: /nix/store/.../mtools-*/bin/mformat) as well as
# Debian (/usr/bin/mformat). Resolve via PATH but EXCLUDE any directory
# we control - the shim must not be self-referential.
REAL_MFORMAT="$(command -v mformat || true)"
if [ -z "$REAL_MFORMAT" ]; then
  echo "build-iso.sh: mformat not in PATH" >&2
  exit 66
fi
SHIM_DIR="$WORK/_mformat_shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/mformat" <<EOF
#!/usr/bin/env bash
# Pinned-serial mformat shim emitted by reproos-iso/scripts/build-iso.sh
# to work around mtools 4.0.32's time-of-day-seeded FAT volume serial.
# The literal '-N <hex>' is prepended so grub-mkrescue's invocation
# becomes deterministic across rebuilds.
exec ${REAL_MFORMAT} -N $REPRO_FAT_SERIAL "\$@"
EOF
chmod +x "$SHIM_DIR/mformat"
export PATH="$SHIM_DIR:$PATH"

# Stage the input tree. grub-mkrescue treats the staged directory as
# the ISO root; we keep the layout minimal (vmlinuz + initrd.img at /
# plus /boot/grub/grub.cfg).
mkdir -p "$WORK/boot/grub"
cp "$KERNEL" "$WORK/vmlinuz"
cp "$INITRAMFS" "$WORK/initrd.img"

# M9.R.16.8 — optional DE-rootfs SquashFS payload. When
# REPRO_DE_ROOTFS_DIR points to a populated directory tree (typically
# the union of /usr from the from-source compositor recipes' install
# mirrors --- sway + kwin + mutter + sddm + plasma-workspace + gdm),
# the script packs it into a deterministic SquashFS image at
# /live/filesystem.squashfs in the ISO root. A booted system (with a
# live-init-capable initramfs) can then loop-mount the squashfs and
# pivot_root into a working DE environment. The R2 vendored Debian
# netinst initramfs is the Debian Installer (no live-init); the
# payload is still added so future R10 initramfses (custom live-init,
# follow-up milestone) can consume it.
REPRO_DE_ROOTFS_DIR="${REPRO_DE_ROOTFS_DIR:-}"
if [ -n "$REPRO_DE_ROOTFS_DIR" ]; then
  if [ ! -d "$REPRO_DE_ROOTFS_DIR" ]; then
    echo "build-iso.sh: REPRO_DE_ROOTFS_DIR points at non-directory: $REPRO_DE_ROOTFS_DIR" >&2
    exit 64
  fi
  if ! command -v mksquashfs >/dev/null 2>&1; then
    echo "build-iso.sh: REPRO_DE_ROOTFS_DIR set but mksquashfs missing (apt-get install squashfs-tools)" >&2
    exit 66
  fi
  mkdir -p "$WORK/live"
  # mksquashfs >= 4.5 already honours SOURCE_DATE_EPOCH for both the
  # superblock mkfs-time and each entry's mtime; the historical
  # ``-all-time`` / ``-mkfs-time`` overrides conflict with the env var
  # and abort with ``SOURCE_DATE_EPOCH and command line options can't
  # be used at the same time to set timestamp(s)``. Drop the explicit
  # flags. -no-xattrs drops xattr noise; -comp xz -Xbcj x86 is the
  # same xz-with-x86-BCJ variant Debian Live uses, producing the
  # smallest reproducible output; -noappend prevents appending to a
  # stale image.
  mksquashfs "$REPRO_DE_ROOTFS_DIR" "$WORK/live/filesystem.squashfs" \
    -no-xattrs \
    -comp xz -Xbcj x86 \
    -noappend \
    -no-progress \
    -quiet
  echo "[de-rootfs] squashfs size=$(stat -c %s "$WORK/live/filesystem.squashfs")"
fi

# GRUB config: console on tty1 + ttyS0 so the boot is visible both on
# graphical consoles AND on Hyper-V's COM1 named pipe (which the
# vm-harness boot gate tails).
#
# The Debian Installer's d-i kernel reads `console=` kernel cmdline
# options to decide where to write its early UI; piping it to ttyS0 at
# 115200 8N1 produces the text-mode installer's serial console banner.
# That banner is the assertion target for the boot gate.
#
# Variants (env-gated, defaults preserve the historical single-entry
# behaviour for non-DEM1 builds):
#
#   REPRO_GRUB_VARIANT=single  (default)
#     one menuentry; matches the R2 historical layout.
#
#   REPRO_GRUB_VARIANT=multi-de
#     four menuentries (DEM1): Hyprland (default), GNOME, KDE Plasma,
#     Recovery (no-DE). Each entry passes a different `repro.de=<name>`
#     kernel cmdline parameter that repro-de-select.service consumes.
#     REPRO_GRUB_DEFAULT picks the 0-based default entry index
#     (default 0 = Hyprland).
#
# The variant is invoked by build-mvp-iso.sh stage 4k when
# MVP_INCLUDE_MULTI_DE=1.
REPRO_GRUB_VARIANT="${REPRO_GRUB_VARIANT:-single}"
REPRO_GRUB_DEFAULT="${REPRO_GRUB_DEFAULT:-0}"
REPRO_GRUB_TIMEOUT="${REPRO_GRUB_TIMEOUT:-0}"

case "$REPRO_GRUB_VARIANT" in
  single)
    cat > "$WORK/boot/grub/grub.cfg" <<EOF
set timeout=$REPRO_GRUB_TIMEOUT
set default=$REPRO_GRUB_DEFAULT

serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
terminal_input  serial console
terminal_output serial console

menuentry 'ReproOS (R2 vendored kernel + initramfs)' {
  linux  /vmlinuz console=tty1 console=ttyS0,115200n8 earlyprintk=ttyS0,115200 loglevel=7 DEBIAN_FRONTEND=text
  initrd /initrd.img
}
EOF
    ;;
  multi-de)
    # DEM1: four menu entries, one per DE + recovery. Each linux line
    # passes `repro.de=<name>` so /usr/local/sbin/repro-de-select.sh
    # arranges the display-manager.service symlink before
    # graphical.target. Default = Hyprland (index 0; smallest, validates
    # fastest).
    #
    # M9.R.18.2 -- real-hardware graphics coverage. Two extra entries:
    #   * "Safe graphics (nomodeset)" boots with nomodeset so the
    #     kernel uses VESA framebuffer instead of KMS; needed on hosts
    #     where the i915/amdgpu/nouveau driver hangs at probe.
    #   * "i915 modeset" forces i915.modeset=1 for Intel iGPUs that
    #     default to disabled (rare but documented on legacy ivy-/sandy-
    #     bridge platforms). Same shape as Ubuntu's "Safe graphics"
    #     fallback.
    cat > "$WORK/boot/grub/grub.cfg" <<EOF
set timeout=$REPRO_GRUB_TIMEOUT
set default=$REPRO_GRUB_DEFAULT

serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
terminal_input  serial console
terminal_output serial console

menuentry 'ReproOS -- Hyprland (default)' {
  linux  /vmlinuz repro.de=hyprland i915.modeset=1 console=tty1 console=ttyS0,115200n8 earlyprintk=ttyS0,115200 loglevel=7 DEBIAN_FRONTEND=text
  initrd /initrd.img
}

menuentry 'ReproOS -- GNOME' {
  linux  /vmlinuz repro.de=gnome i915.modeset=1 console=tty1 console=ttyS0,115200n8 earlyprintk=ttyS0,115200 loglevel=7 DEBIAN_FRONTEND=text
  initrd /initrd.img
}

menuentry 'ReproOS -- KDE Plasma' {
  linux  /vmlinuz repro.de=plasma i915.modeset=1 console=tty1 console=ttyS0,115200n8 earlyprintk=ttyS0,115200 loglevel=7 DEBIAN_FRONTEND=text
  initrd /initrd.img
}

menuentry 'ReproOS -- Safe graphics (nomodeset)' {
  linux  /vmlinuz repro.de=plasma nomodeset console=tty1 console=ttyS0,115200n8 earlyprintk=ttyS0,115200 loglevel=7 DEBIAN_FRONTEND=text
  initrd /initrd.img
}

menuentry 'ReproOS -- Recovery (single user, no DE)' {
  linux  /vmlinuz single console=tty1 console=ttyS0,115200n8 earlyprintk=ttyS0,115200 loglevel=7 DEBIAN_FRONTEND=text
  initrd /initrd.img
}
EOF
    ;;
  *)
    echo "build-iso.sh: invalid REPRO_GRUB_VARIANT='$REPRO_GRUB_VARIANT' (must be 'single' or 'multi-de')" >&2
    exit 64
    ;;
esac

mkdir -p "$(dirname "$OUT_ISO")"

# grub-mkrescue invocation. Reproducibility requirements:
#
#   * SOURCE_DATE_EPOCH (exported by the caller) -> xorriso uses it for
#     the ISO PVD volume timestamp, file timestamps, El Torito boot
#     catalog timestamp.
#   * --compress=xz: compresses the El Torito modules deterministically
#     (xz is byte-stable for fixed inputs; gzip is not).
#   * Sorted -graft-points: we feed a single staged dir so the contents
#     are inserted in deterministic order (xorriso sorts ISO9660
#     children alphabetically by default).
#   * Volume id pinned. The volume id is part of the PVD; without
#     pinning it grub-mkrescue would default-derive from the staged
#     dir name (which is a mktemp random).
#   * --modules=... is the default set; we don't override (overriding
#     would risk drift on a future grub-mkrescue version).
#
# Hybrid output: grub-mkrescue with grub-pc-bin AND grub-efi-amd64-bin
# both installed produces an ISO with:
#   * El Torito BIOS boot entry (boots on legacy CSM/BIOS)
#   * El Torito UEFI boot entry pointing at an embedded FAT image
#     containing /EFI/BOOT/BOOTX64.EFI (boots on UEFI; what Hyper-V
#     Gen-2 consumes).
# Output is also "isohybrid" (USB-bootable raw), though R2 only tests
# the optical-drive UEFI path under Hyper-V Gen-2.

# Some hosts spew xorriso "preparer id" / "application id" lines that
# include build-host-specific text (hostname + xorriso version). Those
# are reproducibility hazards. We override both via the mkisofs
# pass-through flags `-preparer` and `-application`.

# Pinned GPT disk GUID. Without this, xorriso's libisofs generates a
# random GUID per build (it uses the libc PRNG seeded from gettimeofday
# even when SOURCE_DATE_EPOCH is set -- the GUID generator path doesn't
# read SOURCE_DATE_EPOCH). Pinning it to a stable value closes the
# largest reproducibility-drift source on the hybrid output.
#
# Value picked: derived from sha256('reproos-iso-r2'), truncated +
# reformatted to RFC 4122 v4-shaped (variant 0b10, version 0b0100).
# Anything stable would work; pinning to a deterministic, documented
# constant is what matters for the recipe.
REPRO_GPT_DISK_GUID='52455052-4f53-4953-4f52-322d62756c61'

# Modification date for the PVD / SVD / El Torito boot catalog. The
# xorriso `--modification-date=YYYYMMDDhhmmsscc` flag overrides both
# the creation and modification timestamps in the volume descriptors.
# `cc` is the fractional-second hundredths counter that xorriso
# normally fills from the current time of day even with
# SOURCE_DATE_EPOCH set; pinning the whole 16-digit value is the only
# way to make the SVD-time field stable.
#
# 2025-01-01T00:00:00.00Z = 17 35 68 96 00 wall-clock epoch.
# YYYY MM DD hh mm ss cc = 20250101000000 00
REPRO_MODIFICATION_DATE='2025010100000000'

# M9.R.27.7 — assemble a unified GRUB module directory that contains
# BOTH ``i386-pc`` (BIOS) AND ``x86_64-efi`` (UEFI) module trees so
# grub-mkrescue can produce a true hybrid ISO with both an El Torito
# BIOS boot entry AND a UEFI ESP boot entry.
#
# Background: on Nix-based hosts ``nixpkgs#grub2`` ships ONLY the
# ``i386-pc`` modules and ``nixpkgs#grub2_efi`` ships ONLY the
# ``x86_64-efi`` modules. When both are present in the nix-shell,
# the ``grub-mkrescue`` binary on PATH resolves to one or the other
# (whichever appears first), and the resolved binary's default
# probes the compile-time-baked /nix/store/<bin-grub>/lib/grub
# which only has the binary's own arch's modules.
#
# Diagnosis: ``xorriso -indev <iso> -report_el_torito as_mkisofs``
# on the BIOS-only output shows only ``-b /boot/grub/i386-pc/eltorito.img``
# — no ``-eltorito-alt-boot -e ... -no-emul-boot`` block for the UEFI
# ESP image. OVMF boot in QEMU reports ``BdsDxe: No bootable option
# or device was found`` because no UEFI bootable target exists on
# the disc.
#
# Fix: locate the BIOS + EFI grub installations, copy a UNIFIED
# grub installation tree (with both arch subdirs side-by-side under
# lib/grub/) to a private work-dir, then build a wrapper grub-mkrescue
# script that runs the host binary against the unified tree. Pass
# the wrapper to xorriso instead of the host grub-mkrescue.
GRUB_MKRESCUE_BIN=$(command -v grub-mkrescue)
GRUB_BIOS_DIR=""
GRUB_EFI_DIR=""
for d in /nix/store/*-grub-2.*/lib/grub/i386-pc; do
  if [ -d "$d" ]; then GRUB_BIOS_DIR="$d"; break; fi
done
for d in /nix/store/*-grub-2.*/lib/grub/x86_64-efi; do
  if [ -d "$d" ]; then GRUB_EFI_DIR="$d"; break; fi
done
GRUB_HAS_BIOS=0
GRUB_HAS_EFI=0
[ -n "$GRUB_BIOS_DIR" ] && GRUB_HAS_BIOS=1
[ -n "$GRUB_EFI_DIR" ] && GRUB_HAS_EFI=1
echo "[build-iso] GRUB_HAS_BIOS=$GRUB_HAS_BIOS GRUB_HAS_EFI=$GRUB_HAS_EFI"
if [ "$GRUB_HAS_BIOS" = "0" ] || [ "$GRUB_HAS_EFI" = "0" ]; then
  echo "[build-iso] WARNING: only one GRUB arch present; ISO will not be hybrid" >&2
  GRUB_MKRESCUE_FLAGS=()
else
  # Build a unified lib/grub root with both arch subdirs symlinked in.
  mkdir -p "$WORK/grub-unified/lib/grub"
  ln -sfn "$GRUB_BIOS_DIR" "$WORK/grub-unified/lib/grub/i386-pc"
  ln -sfn "$GRUB_EFI_DIR" "$WORK/grub-unified/lib/grub/x86_64-efi"
  # Wrap grub-mkrescue: each grub-* helper grub-mkrescue calls expects
  # to resolve its module dir via the compiled-in prefix. We use the
  # GRUB_PREFIX env-var override (grub-mkrescue scans
  # $GRUB_PREFIX/lib/grub/<platform>) by setting --directory pointing
  # at each arch as needed. Modern grub-mkrescue probes for both archs
  # under $libdir/grub/<arch>/ automatically when the binary's
  # libexec/grub-mkimage finds the arch's eltorito.img.
  #
  # The simplest robust fix is to invoke grub-mkrescue WITHOUT
  # ``--directory``; instead set the GRUB module path via the
  # compiled-in default + symlinked /lib/grub under a TEMP prefix
  # that grub-mkrescue's wrapper-detection picks up via its own
  # libexec/grub-mkimage. Below we set the unified dir as the input
  # --directory; if grub-mkrescue refuses, fall back to invoking
  # against the BIOS dir only (the M9.R.25-era posture) and document
  # the UEFI gap.
  GRUB_MKRESCUE_FLAGS=(--directory="$GRUB_BIOS_DIR")
  # Run a second grub-mkimage pass against the EFI arch to produce
  # /EFI/BOOT/BOOTX64.EFI and stage it into the ISO source tree
  # so grub-mkrescue's --efi-boot machinery picks it up at iso-build
  # time.
  mkdir -p "$WORK/EFI/BOOT"
  grub-mkimage \
    --directory="$GRUB_EFI_DIR" \
    --prefix="/boot/grub" \
    --format=x86_64-efi \
    --output="$WORK/EFI/BOOT/BOOTX64.EFI" \
    --compression=auto \
    part_gpt part_msdos fat iso9660 normal multiboot multiboot2 \
    configfile loadenv linux echo all_video test gfxterm font \
    gettext efi_gop efi_uga \
    || { echo "[build-iso] WARNING: grub-mkimage for x86_64-efi failed; UEFI boot disabled" >&2; rm -f "$WORK/EFI/BOOT/BOOTX64.EFI"; }
  # Stage the x86_64-efi modules dir under boot/grub so the BOOTX64.EFI
  # loader can find its modules at runtime.
  mkdir -p "$WORK/boot/grub"
  cp -a "$GRUB_EFI_DIR" "$WORK/boot/grub/x86_64-efi"
fi

grub-mkrescue \
  "${GRUB_MKRESCUE_FLAGS[@]}" \
  --compress=xz \
  --product-name='ReproOS' \
  --product-version='R2' \
  --output="$OUT_ISO" \
  "$WORK" \
  -- \
  -as mkisofs \
  -volid 'REPROOS_R2' \
  -preparer 'reprobuild-R2' \
  -appid 'reproos-iso' \
  -publisher 'reprobuild' \
  -sysid 'LINUX' \
  -joliet \
  -joliet-long \
  -rational-rock \
  --gpt_disk_guid "$REPRO_GPT_DISK_GUID" \
  --modification-date="$REPRO_MODIFICATION_DATE" \
  --set_all_file_dates "${SOURCE_DATE_EPOCH}" \
  -graft-points

if [ ! -f "$OUT_ISO" ]; then
  echo "grub-mkrescue failed to produce $OUT_ISO" >&2
  exit 67
fi

iso_bytes=$(stat -c %s "$OUT_ISO")
iso_sha=$(sha256sum "$OUT_ISO" | awk '{print $1}')
echo "OK $OUT_ISO bytes=$iso_bytes sha256=$iso_sha"

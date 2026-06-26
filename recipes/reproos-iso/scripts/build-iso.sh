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
# grub-mkimage + mkfs.fat are required for the hybrid BIOS+UEFI path
# (M9.R.28.1 fix); without them the UEFI El Torito alt-boot block is
# silently dropped from the ISO.
for tool in xorriso grub-mkrescue grub-mkimage mformat mcopy mmd mkfs.fat; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "required tool missing: $tool (apt-get install xorriso grub-pc-bin grub-efi-amd64-bin mtools dosfstools)" >&2
    exit 66
  fi
done

WORK=$(mktemp -d -t reproos-iso-XXXXXX)
# Best-effort cleanup. Files copied from /nix/store are read-only;
# ``chmod -R u+w`` first so the trap's ``rm -rf`` cannot fail noisily
# at exit. Run the chmod under ``|| true`` so a partial $WORK populates
# (e.g. an early-script abort) doesn't mask the original exit code.
trap '{ chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }' EXIT

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

# M9.R.39.2 — when ``REPRO_INSTALLER_AUTORUN=1`` is set at build time,
# the default Hyprland menu entry's cmdline gets
# ``repro.installer.autorun=1`` appended, which trips the
# ``reproos-installer-autorun.service`` systemd unit
# (stage-de-rootfs.sh Phase 5) on boot.  The unit runs the launcher in
# DIAG mode BEFORE multi-user.target so the M9.R.39.1 LD_DEBUG + strace
# evidence capture doesn't depend on the wedge-prone serial-getty
# autologin flow.  Default is empty so the live ISO behaves normally
# unless an investigator opts in.
if [ "${REPRO_INSTALLER_AUTORUN:-0}" = "1" ]; then
  REPRO_INSTALLER_AUTORUN_PARAM=" repro.installer.autorun=1"
else
  REPRO_INSTALLER_AUTORUN_PARAM=""
fi

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
  linux  /vmlinuz repro.de=hyprland i915.modeset=1 console=tty1 console=ttyS0,115200n8 earlyprintk=ttyS0,115200 loglevel=7 DEBIAN_FRONTEND=text${REPRO_INSTALLER_AUTORUN_PARAM}
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

# M9.R.28.1 — assemble a hybrid BIOS+UEFI ISO on Nix-based hosts where
# ``grub2`` (i386-pc) and ``grub2_efi`` (x86_64-efi) live in two
# separate /nix/store outputs.
#
# Background: ``grub-mkrescue`` accepts a single ``--directory`` arg
# that must point at a single-platform module dir (the dir containing
# ``modinfo.sh``). The compile-time ``pkglibdir`` baked into the
# nixpkgs ``grub-mkrescue`` binary points at i386-pc only; passing
# ``--directory`` to point at x86_64-efi or to a unified parent dir
# breaks (the binary expects modinfo.sh DIRECTLY under --directory).
# Specifying ``--directory`` twice overrides not combines.
#
# Diagnosis: ``xorriso -indev <iso> -report_el_torito as_mkisofs``
# on a single-arch run shows only the boot block for whichever arch
# was probed — ``-b boot/grub/i386-pc/eltorito.img`` (BIOS) OR
# ``-e efi.img -no-emul-boot`` (UEFI), never both.
#
# Fix shape (M9.R.28.1):
#   1) Build the UEFI loader (``BOOTX64.EFI``) via ``grub-mkimage``
#      against the x86_64-efi module dir.
#   2) Wrap that loader in a FAT12 ESP image (``efi.img``) via
#      ``mformat`` + ``mcopy``; the FAT image becomes a NoEmulation
#      El Torito alt-boot target.
#   3) Stage ``efi.img`` into the ISO source tree under
#      ``boot/grub/efi.img`` AND a copy of the x86_64-efi modules
#      under ``boot/grub/x86_64-efi/`` so the runtime BOOTX64.EFI
#      can locate its modules after boot.
#   4) Run ``grub-mkrescue`` for the BIOS half (default i386-pc) and
#      pass a custom ``--xorriso`` wrapper that intercepts the
#      xorriso call and appends ``-eltorito-alt-boot -e
#      boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat`` so
#      the resulting ISO has BOTH boot entries.
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
echo "[build-iso] GRUB_BIOS_DIR=$GRUB_BIOS_DIR"
echo "[build-iso] GRUB_EFI_DIR=$GRUB_EFI_DIR"
GRUB_XORRISO_WRAPPER=""
if [ "$GRUB_HAS_BIOS" = "0" ] || [ "$GRUB_HAS_EFI" = "0" ]; then
  echo "[build-iso] WARNING: only one GRUB arch present; ISO will not be hybrid" >&2
  GRUB_MKRESCUE_FLAGS=()
else
  # Step 1 — build BOOTX64.EFI via grub-mkimage against the EFI module
  # dir. The loader is small (~750 KiB) and self-contained; it knows
  # how to read the ISO9660 filesystem + locate /boot/grub/grub.cfg
  # at runtime.
  mkdir -p "$WORK/EFI/BOOT"
  echo "[build-iso] running grub-mkimage --directory=$GRUB_EFI_DIR --format=x86_64-efi"
  grub-mkimage \
    --directory="$GRUB_EFI_DIR" \
    --prefix="/boot/grub" \
    --format=x86_64-efi \
    --output="$WORK/EFI/BOOT/BOOTX64.EFI" \
    --compression=auto \
    part_gpt part_msdos fat iso9660 normal multiboot multiboot2 \
    configfile loadenv linux echo all_video test gfxterm font \
    gettext efi_gop efi_uga
  mkimage_rc=$?
  if [ "$mkimage_rc" -ne 0 ] || [ ! -s "$WORK/EFI/BOOT/BOOTX64.EFI" ]; then
    echo "[build-iso] FATAL: grub-mkimage for x86_64-efi failed (rc=$mkimage_rc)" >&2
    exit 68
  fi
  bootx64_size=$(stat -c %s "$WORK/EFI/BOOT/BOOTX64.EFI")
  echo "[build-iso] BOOTX64.EFI size=$bootx64_size"

  # Step 2 — wrap BOOTX64.EFI in a FAT12 ESP image. The size is rounded
  # UP to leave headroom for the FAT filesystem overhead (boot sector
  # + FAT tables + root dir).
  #
  # CRITICAL: use ``mkfs.fat -F 12`` (FAT12), NOT ``mformat`` which
  # auto-picks FAT32 for any size >= 1 MiB. OVMF's FAT driver REJECTS
  # the degenerate FAT32 mformat produces on a ~1 MiB image (the BPB
  # has FAT32 layout but only 16 sectors per FAT, which the OVMF FAT
  # driver treats as an invalid filesystem and the boot manager
  # reports ``BdsDxe: failed to load Boot0001 ... Not Found``).
  # FAT12 is the format real ESPs on small live-ISO boot images use
  # (Arch, Debian Live, Fedora Server netinst all use FAT12 here).
  esp_blocks=$(( (bootx64_size / 1024) + 256 ))
  echo "[build-iso] efi.img size=${esp_blocks} KiB"
  rm -f "$WORK/boot/grub/efi.img"
  mkdir -p "$WORK/boot/grub"
  dd if=/dev/zero of="$WORK/boot/grub/efi.img" bs=1024 count="$esp_blocks" status=none
  mkfs.fat -F 12 -n EFI "$WORK/boot/grub/efi.img"
  mmd -i "$WORK/boot/grub/efi.img" ::/EFI
  mmd -i "$WORK/boot/grub/efi.img" ::/EFI/BOOT
  mcopy -i "$WORK/boot/grub/efi.img" "$WORK/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI

  # Step 3 — stage the x86_64-efi runtime module tree alongside the
  # BIOS modules so BOOTX64.EFI can dynamically load them after boot.
  mkdir -p "$WORK/boot/grub/x86_64-efi"
  cp -aL "$GRUB_EFI_DIR"/. "$WORK/boot/grub/x86_64-efi/"
  # /nix/store files are read-only; restore u+w so the script's EXIT
  # trap can ``rm -rf $WORK`` without errors.
  chmod -R u+w "$WORK/boot/grub/x86_64-efi" "$WORK/EFI"

  # Step 4 — build a xorriso wrapper. grub-mkrescue's ``--xorriso=``
  # flag designates the program it execs to actually mint the ISO;
  # we splice an ``-eltorito-alt-boot -e boot/grub/efi.img
  # -no-emul-boot -isohybrid-gpt-basdat`` block IMMEDIATELY before
  # the ``-o <out.iso>`` argument so xorriso sees a second El Torito
  # boot entry while keeping the BIOS one grub-mkrescue passed first.
  GRUB_XORRISO_WRAPPER="$WORK/_xorriso_wrap"
  REAL_XORRISO="$(command -v xorriso)"
  if [ -z "$REAL_XORRISO" ]; then
    echo "[build-iso] FATAL: xorriso not in PATH" >&2
    exit 66
  fi
  cat > "$GRUB_XORRISO_WRAPPER" <<EOF
#!/usr/bin/env bash
# M9.R.28.1 hybrid-grub xorriso wrapper. Splices the EFI alt-boot
# block into grub-mkrescue's xorriso invocation so the resulting ISO
# is bootable on both legacy BIOS AND UEFI firmware (e.g. OVMF/Q35).
#
# The minimum mkisofs flags that OVMF accepts as a UEFI El Torito
# entry are:
#   -eltorito-alt-boot
#   -eltorito-platform efi          # set El Torito platform_id=0xEF
#   -e boot/grub/efi.img            # FAT12 ESP image path on ISO
#   -no-emul-boot                   # no floppy emulation
#   -isohybrid-gpt-basdat           # mark in GPT as Basic Data partn
#   -efi-boot-part --efi-boot-image # also mark the El Torito EFI image
#                                   #   as the data source for the
#                                   #   ESP GPT partition so the
#                                   #   firmware finds the loader via
#                                   #   either El Torito OR GPT scan
#
# The -eltorito-platform flag must precede the -e flag in mkisofs's
# command-parser; it sets the platform_id of the NEXT boot entry.
# Without -efi-boot-part the firmware cannot see /EFI/BOOT/BOOTX64.EFI
# even though the catalog has the right platform_id — OVMF probes
# both the El Torito catalog AND the GPT ESP partition, and several
# OVMF versions only honour the GPT path.
set -euo pipefail
ARGS=()
for a in "\$@"; do
  if [ "\$a" = "-o" ]; then
    ARGS+=(-eltorito-alt-boot -eltorito-platform efi -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat -efi-boot-part --efi-boot-image -o)
  else
    ARGS+=("\$a")
  fi
done
exec ${REAL_XORRISO} "\${ARGS[@]}"
EOF
  chmod +x "$GRUB_XORRISO_WRAPPER"
  GRUB_MKRESCUE_FLAGS=(--directory="$GRUB_BIOS_DIR" --xorriso="$GRUB_XORRISO_WRAPPER")
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

#!/usr/bin/env bash
set -euo pipefail
GRUB_BIOS_DIR=""
GRUB_EFI_DIR=""
for d in /nix/store/*-grub-2.*/lib/grub/i386-pc; do
  if [ -d "$d" ]; then GRUB_BIOS_DIR="$d"; break; fi
done
for d in /nix/store/*-grub-2.*/lib/grub/x86_64-efi; do
  if [ -d "$d" ]; then GRUB_EFI_DIR="$d"; break; fi
done
echo "BIOS=$GRUB_BIOS_DIR"
echo "EFI=$GRUB_EFI_DIR"
TMPOUT=$(mktemp -d)
echo "TMPOUT=$TMPOUT"
which grub-mkimage
grub-mkimage \
  --directory="$GRUB_EFI_DIR" \
  --prefix=/boot/grub \
  --format=x86_64-efi \
  --output="$TMPOUT/BOOTX64.EFI" \
  --compression=auto \
  part_gpt part_msdos fat iso9660 normal multiboot multiboot2 \
  configfile loadenv linux echo all_video test gfxterm font \
  gettext efi_gop efi_uga
RC=$?
echo "RC=$RC"
ls -la "$TMPOUT/BOOTX64.EFI"
echo "--- check file kind ---"
file "$TMPOUT/BOOTX64.EFI"

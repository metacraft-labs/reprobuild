#!/usr/bin/env bash
set -euo pipefail
GRUB_BIOS_DIR=/nix/store/rb4c7fnfn2zzbns1c2q62yf55pgizf3j-grub-2.12/lib/grub/i386-pc
GRUB_EFI_DIR=/nix/store/ki1cfmlv5wxcca1xr7gpjpf60969czfw-grub-2.12/lib/grub/x86_64-efi
STAGE=/tmp/m9r28-direct
rm -rf "$STAGE"
mkdir -p "$STAGE/boot/grub/i386-pc" "$STAGE/EFI/BOOT"
cp /opt/repro/reprobuild/recipes/reproos-iso/vendor/vmlinuz-debian-netinst "$STAGE/vmlinuz"
cp /opt/repro/reprobuild/recipes/reproos-iso/vendor/initrd.img-debian-netinst "$STAGE/initrd.img"
cat > "$STAGE/boot/grub/grub.cfg" <<EOF
set timeout=0
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial console
menuentry "ReproOS" {
  linux  /vmlinuz console=ttyS0,115200n8
  initrd /initrd.img
}
EOF

# 1. Build BOOTX64.EFI
grub-mkimage \
  --directory="$GRUB_EFI_DIR" \
  --prefix="/boot/grub" \
  --format=x86_64-efi \
  --output="$STAGE/EFI/BOOT/BOOTX64.EFI" \
  --compression=auto \
  part_gpt part_msdos fat iso9660 normal multiboot multiboot2 \
  configfile loadenv linux echo all_video test gfxterm font \
  gettext efi_gop efi_uga

# 2. Build BIOS eltorito.img
grub-mkimage \
  --directory="$GRUB_BIOS_DIR" \
  --prefix="/boot/grub" \
  --format=i386-pc-eltorito \
  --output="$STAGE/boot/grub/i386-pc/eltorito.img" \
  --compression=auto \
  biosdisk iso9660 part_gpt part_msdos fat normal multiboot multiboot2 \
  configfile loadenv linux echo all_video test gfxterm font gettext

# 3. Build FAT12 ESP image via mkfs.fat (not mformat — mformat
#    auto-picks FAT32 for any size which OVMF's FAT driver may reject
#    on a 1 MiB image whose FAT32 metadata is degenerate).
dd if=/dev/zero of="$STAGE/boot/grub/efi.img" bs=1024 count=1024 status=none
mkfs.fat -F 12 -n EFI "$STAGE/boot/grub/efi.img"
mmd -i "$STAGE/boot/grub/efi.img" ::/EFI
mmd -i "$STAGE/boot/grub/efi.img" ::/EFI/BOOT
mcopy -i "$STAGE/boot/grub/efi.img" "$STAGE/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI

ls -la "$STAGE/EFI/BOOT/BOOTX64.EFI" "$STAGE/boot/grub/i386-pc/eltorito.img" "$STAGE/boot/grub/efi.img"

# 4. Build hybrid ISO directly with xorriso
xorriso -as mkisofs \
  -V REPROOS \
  -o /tmp/direct.iso \
  -b boot/grub/i386-pc/eltorito.img \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  --grub2-boot-info \
  --grub2-mbr "$GRUB_BIOS_DIR/boot_hybrid.img" \
  --protective-msdos-label \
  -eltorito-alt-boot \
  -eltorito-platform efi \
  -e boot/grub/efi.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  -efi-boot-part --efi-boot-image \
  "$STAGE"
ls -la /tmp/direct.iso
xorriso -indev /tmp/direct.iso -report_el_torito plain 2>&1 | tail -15

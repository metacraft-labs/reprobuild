#!/usr/bin/env bash
#
# Take one measured boot's own attestation evidence.
#
# Assembles a unified kernel image, boots it in a transient QEMU guest
# through TPM-enabled UEFI firmware with a software TPM attached, has the
# guest quote its own registers, and brings the evidence home: the
# attestation structure, its signature, the event log the firmware wrote,
# AND THE ATTESTATION KEY'S PUBLIC PART.
#
# The last of those is not decoration. The key is created inside the
# guest and dies with it, and one signature does not determine one key --
# recovery over a single (attest, signature) pair yields several
# candidates that all verify, and the attest names only the key's
# QUALIFIED name, whose parent component is never recorded here. A
# signature pinned without its key can therefore never be checked by
# anyone. Three captures were pinned that way before this was noticed.
# See the README beside this script.
#
#   take-attested-boot-evidence.sh <workdir> [<kernel command line>]
#
# Environment:
#   ATTEST_BOOT_BOUND_HEX   the 64 bytes the quote must bind, hex. The
#                           caller derives these through the binding
#                           discipline; the guest is handed them over a
#                           channel OUTSIDE the measurement, so it can
#                           neither choose them nor derive them from
#                           anything it measured.
#   ATTEST_BOOT_UKI_TOOL    the image assembler to build the image with.
#   ATTEST_BOOT_STUB        the UEFI stub to build it from.
#   ATTEST_BOOT_FIRMWARE    a firmware directory carrying OVMF_CODE.fd
#                           and OVMF_VARS.fd. IT MUST BE A TPM-ENABLED
#                           BUILD: firmware compiled without TPM support
#                           boots perfectly, reports every register at
#                           zero, and exposes no event log at all, which
#                           is a failure that looks like a working guest.
#   ATTEST_BOOT_SWTPM_BIN   directory holding the software TPM.
#   ATTEST_BOOT_TPM2_BIN    directory holding the TPM 2.0 command tools.
#   ATTEST_BOOT_KERNEL      the kernel to boot.
#   ATTEST_BOOT_KMOD        its module tree.
#   ATTEST_BOOT_BUSYBOX     a shell and core utilities for the initramfs.
#
# Two wiring facts that each cost hours to find, recorded so they are not
# rediscovered:
#
#   * The guest's TPM chardev must point at the software TPM's CONTROL
#     socket, not at its data socket. Pointed at the data socket, the
#     emulator handshake never completes, the guest comes up with no TPM,
#     and every register reads zero -- the SAME symptom as firmware built
#     without TPM support, from an entirely different cause.
#   * The firmware requires system-management mode, so the machine needs
#     `smm=on` and the flash device needs its `secure` property set, or
#     it refuses to start.
#
# Everything it creates is torn down unconditionally, including on the
# failure paths: the guest is transient, the software TPM is a direct
# child, and its state directory is removed.
set -euo pipefail

WORK="${1:?workdir}"
CMDLINE="${2:-console=ttyS0 reproos.attest=1}"

need() {
  local name=$1 value=${2:-}
  if [ -z "$value" ]; then
    echo "take-attested-boot-evidence: $name is not set. This harness" >&2
    echo "  drives real firmware and a real TPM implementation; it names" >&2
    echo "  what it could not find rather than reporting a skip, because" >&2
    echo "  an evidence-taking run that quietly did nothing is worse" >&2
    echo "  than one that failed." >&2
    exit 69
  fi
  printf '%s' "$value"
}
STUB=$(need ATTEST_BOOT_STUB "${ATTEST_BOOT_STUB:-}")
OVMF=$(need ATTEST_BOOT_FIRMWARE "${ATTEST_BOOT_FIRMWARE:-}")
SWTPM=$(need ATTEST_BOOT_SWTPM_BIN "${ATTEST_BOOT_SWTPM_BIN:-}")
TOOLS=$(need ATTEST_BOOT_TPM2_BIN "${ATTEST_BOOT_TPM2_BIN:-}")
BUSYBOX=$(need ATTEST_BOOT_BUSYBOX "${ATTEST_BOOT_BUSYBOX:-}")
KERNEL=$(need ATTEST_BOOT_KERNEL "${ATTEST_BOOT_KERNEL:-}")
KMOD=$(need ATTEST_BOOT_KMOD "${ATTEST_BOOT_KMOD:-}")
UKI_TOOL=$(need ATTEST_BOOT_UKI_TOOL "${ATTEST_BOOT_UKI_TOOL:-}")

rm -rf "$WORK"; mkdir -p "$WORK"/{initramfs,out,esp}
cd "$WORK"

# ---------------------------------------------------------------- initramfs
IR=$WORK/initramfs
mkdir -p "$IR"/{bin,dev,proc,sys,modules,nix/store,out,tmp,run}
cp "$BUSYBOX" "$IR/bin/busybox"
chmod +x "$IR/bin/busybox"
# busybox is dynamically linked against the store; the interpreter and the
# libraries have to exist inside the initramfs at their real absolute paths,
# because nothing is mounted yet when init starts.
for lib in $(ldd "$BUSYBOX" | grep -o '/nix/store/[^ ]*' | sort -u); do
  mkdir -p "$IR$(dirname "$lib")"
  cp -L "$lib" "$IR$lib"
done
for ap in sh mount umount cp cat echo ls mkdir insmod sync poweroff sleep dd printf; do
  ln -sf busybox "$IR/bin/$ap"
done
for m in fs/netfs/netfs net/9p/9pnet drivers/virtio/virtio_ring drivers/virtio/virtio \
         drivers/virtio/virtio_pci_legacy_dev drivers/virtio/virtio_pci_modern_dev \
         drivers/virtio/virtio_pci net/9p/9pnet_virtio fs/9p/9p \
         drivers/char/hw_random/rng-core drivers/char/tpm/tpm drivers/char/tpm/tpm_crb; do
  b=$(basename "$m")
  xz -dc "$KMOD/kernel/$m.ko.xz" > "$IR/modules/$b.ko"
done

cat > "$IR/init" <<'INIT'
#!/bin/sh
export PATH=/bin
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
mount -t securityfs securityfs /sys/kernel/security 2>/dev/null

for m in netfs 9pnet virtio_ring virtio virtio_pci_legacy_dev virtio_pci_modern_dev \
         virtio_pci 9pnet_virtio 9p rng-core tpm tpm_crb; do
  insmod /modules/$m.ko 2>/dev/null
done

mount -t 9p -o trans=virtio,version=9p2000.L,ro nixstore /nix/store || echo "ATTESTED-BOOT-FAIL: nixstore"
mount -t 9p -o trans=virtio,version=9p2000.L,rw outshare /out   || echo "ATTESTED-BOOT-FAIL: outshare"

echo "ATTESTED-BOOT-BEGIN"
TOOLS=@TOOLS@
export PATH=$TOOLS:$PATH
export TPM2TOOLS_TCTI=device:/dev/tpmrm0

cp /sys/kernel/security/tpm0/binary_bios_measurements /out/binary_bios_measurements \
  || echo "ATTESTED-BOOT-FAIL: no event log"
for a in sha1 sha256 sha384 sha512; do
  for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23; do
    v=$(cat /sys/class/tpm/tpm0/pcr-$a/$i 2>/dev/null) && echo "$a $i $v"
  done
done > /out/pcrs.txt

Q=$(cat /out/challenge.hex 2>/dev/null)
cd /tmp
$TOOLS/tpm2_createek -c ek.ctx -G rsa -u ek.pub          >/out/createek.log 2>&1 || echo "ATTESTED-BOOT-FAIL: createek"
$TOOLS/tpm2_createak -C ek.ctx -c ak.ctx -G ecc -g sha256 -s ecdsa \
     -u ak.pub -f pem -n ak.name                          >/out/createak.log 2>&1 || echo "ATTESTED-BOOT-FAIL: createak"
$TOOLS/tpm2_flushcontext -t >/dev/null 2>&1
$TOOLS/tpm2_quote -c ak.ctx -l @PCRSEL@ -q "$Q" \
     -m /out/quote.msg -s /out/quote.sig -o /out/quote.pcrs -f tss \
                                                          >/out/quote.log 2>&1 || echo "ATTESTED-BOOT-FAIL: quote"
cp ak.pub /out/ak.pub.pem 2>/dev/null
cp ak.name /out/ak.name 2>/dev/null
$TOOLS/tpm2_readpublic -c ak.ctx -o /out/ak.pub.tss -f tss >/out/readpublic.log 2>&1
sync
echo "ATTESTED-BOOT-DONE"
poweroff -f
INIT
sed -i "s|@TOOLS@|$TOOLS|; s|@PCRSEL@|${PCRSEL:-sha256:0,1,2,3,4,5,6,7,11}|" "$IR/init"
chmod +x "$IR/init"

# Deterministic: a fixed mtime on every member and a sorted member list,
# so two runs that differ only in the kernel command line produce
# byte-identical initrd bytes and therefore an identical .initrd
# measurement. Without this, every rebuild moves a second section and
# "the command line moved the measurement" is not a claim the evidence
# supports.
find "$IR" -exec touch -h -d @0 {} + 2>/dev/null || true
( cd "$IR" && find . -print0 | LC_ALL=C sort -z |
    cpio -o -H newc --quiet --reproducible -0 ) > "$WORK/initrd.img"

# ---------------------------------------------------------------- UKI
printf '%s' "$CMDLINE" > "$WORK/cmdline.txt"
cat > "$WORK/osrel.txt" <<'OSREL'
ID=reproos-att
PRETTY_NAME="attested boot probe"
VERSION_ID=0
OSREL
printf '%s' "$CMDLINE" > "$WORK/cmdline.txt"

SOURCE_DATE_EPOCH=1700000000 "$UKI_TOOL" assemble \
  --stub "$STUB" --kernel "$KERNEL" --initrd "$WORK/initrd.img" \
  --cmdline "$CMDLINE" --uname "6.12.85" --os-release-version "0" \
  --source-date-epoch 1700000000 --out "$WORK/uki.efi" \
  --manifest "$WORK/uki.json" --digest-out "$WORK/uki.sha256" \
  --cmdline-out "$WORK/uki.cmdline"

# ---------------------------------------------------------------- ESP
truncate -s 96M "$WORK/esp.img"
mkfs.vfat -n ESP -F 32 "$WORK/esp.img" >/dev/null
export MTOOLS_SKIP_CHECK=1
mmd -i "$WORK/esp.img" ::/EFI ::/EFI/BOOT
mcopy -i "$WORK/esp.img" "$WORK/uki.efi" ::/EFI/BOOT/BOOTX64.EFI

# ---------------------------------------------------------------- swtpm
TPMDIR=$WORK/tpmstate; mkdir -p "$TPMDIR"
"$SWTPM/swtpm" socket --tpmstate dir="$TPMDIR" \
  --ctrl type=unixio,path="$WORK/swtpm.sock" \
  --tpm2 --flags not-need-init,startup-clear \
  >"$WORK/swtpm.log" 2>&1 &
SWTPM_PID=$!
# Unconditional teardown, and it runs on every failure path above as
# well as on success: the software TPM is killed and its state directory
# removed. The evidence directory is left, because it is the output.
cleanup() {
  kill "$SWTPM_PID" 2>/dev/null || true
  wait "$SWTPM_PID" 2>/dev/null || true
  rm -rf "$TPMDIR" "$WORK/swtpm.sock" "$WORK/swtpm.sock.ctrl"
}
trap cleanup EXIT
for _ in $(seq 1 100); do [ -S "$WORK/swtpm.sock" ] && break; sleep 0.1; done
if [ ! -S "$WORK/swtpm.sock" ]; then echo "SWTPM DID NOT START:"; cat "$WORK/swtpm.log"; exit 1; fi
echo "[swtpm] listening"

# ---------------------------------------------------------------- boot
cp "$OVMF/FV/OVMF_VARS.fd" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"
printf '%s' "$(need ATTEST_BOOT_BOUND_HEX "${ATTEST_BOOT_BOUND_HEX:-}")" \
  > "$WORK/out/challenge.hex"

timeout 180 qemu-system-x86_64 \
  -machine q35,smm=on,accel=kvm:tcg -m 2048 -smp 2 -no-reboot \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF/FV/OVMF_CODE.fd" \
  -drive if=pflash,format=raw,unit=1,file="$WORK/vars.fd" \
  -drive file="$WORK/esp.img",format=raw,if=none,id=esp0 \
  -device ide-hd,drive=esp0,bus=ide.0,bootindex=0 \
  -chardev socket,id=chrtpm,path="$WORK/swtpm.sock" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-crb,tpmdev=tpm0 \
  -virtfs local,path=/nix/store,mount_tag=nixstore,security_model=none,readonly=on \
  -virtfs local,path="$WORK/out",mount_tag=outshare,security_model=none \
  -debugcon "file:$WORK/ovmf.log" -global isa-debugcon.iobase=0x402 \
  -display none -monitor none -serial "file:$WORK/console.log" >"$WORK/qemu.err" 2>&1 </dev/null || true

echo "=== artifacts:"; ls -la "$WORK/out"

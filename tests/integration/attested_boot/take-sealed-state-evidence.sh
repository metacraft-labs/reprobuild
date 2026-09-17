#!/usr/bin/env bash
#
# Take one machine's evidence about state volumes sealed to its own
# measured boot.
#
# This is the sibling of `take-attested-boot-evidence.sh`. That one asks
# a guest what it measured; this one asks whether a secret the guest's
# TPM is holding can still be recovered after the machine is power
# cycled, after its boot entry is replaced, and after its boot entry is
# ALTERED.
#
# One run is ONE MACHINE across FIVE POWER CYCLES. The software TPM's
# state directory, the UEFI variable store and both encrypted block
# devices persist across all five; only the image on the EFI system
# partition changes. Each cycle is a separate firmware start, so the
# registers are re-extended from their reset values every time and
# nothing carries over except what is on disk or in the TPM.
#
#   cycle   image on the ESP       what the guest is asked to do
#   ------  ---------------------  -------------------------------------
#   enroll  generation A           create two LUKS2 volumes with a key
#                                  drawn from the kernel's RNG, write a
#                                  marker into each, and seal the key to
#                                  the register the stub measured the
#                                  image into
#   reboot  generation A           recover the key and open both volumes
#   reseal  generation A           recover the key, then re-seal it under
#                                  the register value generation B WILL
#                                  produce, computed from generation B's
#                                  image bytes before it has ever run
#   switch  generation B           recover the key from the NEW sealed
#                                  object and open both volumes; the OLD
#                                  sealed object must refuse
#   tamper  generation A with one  both sealed objects must refuse, and
#           character of kernel    the volumes must still be locked
#           command line altered
#
# Every cycle writes `out/report-<cycle>.txt`, a flat key=value record,
# and the sealed objects, their names, the policy digests and the event
# logs are brought home beside them.
#
#   take-sealed-state-evidence.sh <workdir>
#
# Environment (each is named out loud when missing; this harness never
# skips, because a run that quietly did nothing is worse than one that
# failed):
#
#   SEAL_UKI_TOOL        the image assembler to build the images with.
#   SEAL_STUB            the UEFI stub to build them from.
#   SEAL_MEASURE_TOOL    the `repro` command line, used to compute what
#                        a generation WILL measure to, from its bytes.
#   SEAL_FIRMWARE        a firmware directory carrying OVMF_CODE.fd and
#                        OVMF_VARS.fd. IT MUST BE A TPM-ENABLED BUILD:
#                        firmware without TPM support boots perfectly and
#                        reports every register at zero.
#   SEAL_SWTPM_BIN       directory holding the software TPM.
#   SEAL_TPM2_BIN        directory holding the TPM 2.0 command tools.
#   SEAL_CRYPTSETUP      the cryptsetup binary the guest runs.
#   SEAL_KERNEL          the kernel to boot.
#   SEAL_KMOD            its module tree.
#   SEAL_BUSYBOX         a STATIC shell and core utilities.
#
# Optional:
#
#   SEAL_RECOVERY_FALLBACK=1
#       Enrol a second key slot holding a well-known recovery key, and
#       have the guest fall back to it whenever the TPM refuses to
#       release the sealed one. This is the FAILURE MODE the third check
#       exists to detect -- a machine that says "no" and opens the disk
#       anyway -- and running it produces the negative control that shows
#       the "it refused" and the "it stayed locked" questions are not the
#       same question. Only the `enroll` and `tamper` cycles are run
#       under it. NEVER use this for a capture meant to represent
#       correct behaviour.
#
#   SEAL_CYCLES="enroll reboot ..."
#       Run a subset of the cycles, in the given order.
#
# The guest's init is IDENTICAL in every cycle and is told which cycle it
# is over the shared directory rather than on the kernel command line.
# That is not a convenience: the command line and the initramfs are both
# inside the launch measurement, so an init that branched on either would
# move the very value the experiment holds fixed.
#
# Three wiring facts that each cost hours, recorded so they are not
# rediscovered:
#
#   * The guest's TPM character device must point at the software TPM's
#     CONTROL socket, not at its data socket. Pointed at the data socket
#     the emulator handshake never completes, the guest comes up with no
#     TPM, and every register reads zero -- the SAME symptom as firmware
#     built without TPM support, from an entirely different cause.
#   * The firmware requires system-management mode, so the machine needs
#     `smm=on` and the flash device needs its `secure` property set.
#   * The firmware finds the EFI system partition on a SATA device. On a
#     virtio block device, even with an explicit bootindex, the boot
#     manager selects a "UEFI Non-Block Boot Device" and never reaches
#     it. The two encrypted volumes are therefore virtio and the ESP is
#     not.
#
# Everything the run creates is torn down unconditionally, including on
# the failure paths. The evidence directory is left, because it is the
# output.
set -euo pipefail

WORK="${1:?workdir}"

need() {
  local name=$1 value=${2:-}
  if [ -z "$value" ]; then
    echo "take-sealed-state-evidence: $name is not set. This harness" >&2
    echo "  drives real firmware, a real TPM implementation and real" >&2
    echo "  LUKS2 volumes; it names what it could not find rather than" >&2
    echo "  reporting a skip, because a run that quietly did nothing is" >&2
    echo "  worse than one that failed." >&2
    exit 69
  fi
  printf '%s' "$value"
}
STUB=$(need SEAL_STUB "${SEAL_STUB:-}")
OVMF=$(need SEAL_FIRMWARE "${SEAL_FIRMWARE:-}")
SWTPM=$(need SEAL_SWTPM_BIN "${SEAL_SWTPM_BIN:-}")
TOOLS=$(need SEAL_TPM2_BIN "${SEAL_TPM2_BIN:-}")
BUSYBOX=$(need SEAL_BUSYBOX "${SEAL_BUSYBOX:-}")
KERNEL=$(need SEAL_KERNEL "${SEAL_KERNEL:-}")
KMOD=$(need SEAL_KMOD "${SEAL_KMOD:-}")
UKI_TOOL=$(need SEAL_UKI_TOOL "${SEAL_UKI_TOOL:-}")
MEASURE=$(need SEAL_MEASURE_TOOL "${SEAL_MEASURE_TOOL:-}")
CRYPTSETUP=$(need SEAL_CRYPTSETUP "${SEAL_CRYPTSETUP:-}")

FALLBACK="${SEAL_RECOVERY_FALLBACK:-0}"
DEFAULT_CYCLES="enroll reboot reseal switch tamper"
if [ "$FALLBACK" = "1" ]; then DEFAULT_CYCLES="enroll tamper"; fi
CYCLES="${SEAL_CYCLES:-$DEFAULT_CYCLES}"

# The three command lines. They are the SAME LENGTH and differ in one
# character, so any difference between two of these images is confined to
# the `.cmdline` section and the claim "the command line moved the
# measurement" is one the evidence supports rather than one it assumes.
CMDLINE_A='console=ttyS0 reproos.gen=a'
CMDLINE_B='console=ttyS0 reproos.gen=b'
CMDLINE_T='console=ttyS0 reproos.gen=x'

rm -rf "$WORK"; mkdir -p "$WORK"/{initramfs,out,tpmstate}
cd "$WORK"

# ---------------------------------------------------------------- initramfs
IR=$WORK/initramfs
mkdir -p "$IR"/{bin,dev,proc,sys,modules,nix/store,out,tmp,run}
if ldd "$BUSYBOX" >/dev/null 2>&1; then
  echo "take-sealed-state-evidence: SEAL_BUSYBOX must be statically linked;" >&2
  echo "  $BUSYBOX is not. Nothing is mounted when init starts, so a" >&2
  echo "  dynamic shell cannot find its own interpreter." >&2
  exit 69
fi
cp "$BUSYBOX" "$IR/bin/busybox"
chmod +x "$IR/bin/busybox"
for ap in sh mount umount cp cat echo ls mkdir rm insmod sync poweroff sleep \
          dd printf od tr sed grep head cut wc env chmod ln true false; do
  ln -sf busybox "$IR/bin/$ap"
done

# The module set is resolved here, on the host, and written into the
# initramfs as an ordered list. Resolving it in the guest would need
# modinfo; hard-coding it in the init would put a host-specific list
# inside the measurement for no reason. Dependencies are walked
# transitively, and a name that resolves to no file is dropped -- it is
# built into this kernel, and insmod would refuse it.
declare -A MOD_SEEN=()
MOD_ORDER=()
modfile() {
  local n=$1 p
  for cand in "${n//_/-}" "${n//-/_}"; do
    p=$(find -L "$KMOD/kernel" \( -name "$cand.ko.xz" -o -name "$cand.ko" \) \
        2>/dev/null | head -1)
    [ -n "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 0
}
addmod() {
  local key=${1//-/_} path deps dep base
  [ -n "${MOD_SEEN[$key]:-}" ] && return 0
  path=$(modfile "$1")
  [ -z "$path" ] && return 0
  MOD_SEEN[$key]=1
  deps=$(modinfo -F depends "$path" 2>/dev/null || true)
  if [ -n "$deps" ]; then
    IFS=, read -r -a deparr <<< "$deps"
    for dep in "${deparr[@]}"; do [ -n "$dep" ] && addmod "$dep"; done
  fi
  base=$(basename "$path"); base=${base%.xz}; base=${base%.ko}
  case "$path" in
    *.ko.xz) xz -dc "$path" > "$IR/modules/$base.ko" ;;
    *)       cp "$path" "$IR/modules/$base.ko" ;;
  esac
  MOD_ORDER+=("$base")
}
for m in netfs 9pnet virtio_ring virtio virtio_pci_legacy_dev \
         virtio_pci_modern_dev virtio_pci 9pnet_virtio 9p virtio_blk \
         rng-core virtio-rng tpm tpm_crb \
         cbc xts af_alg algif_skcipher algif_hash \
         dm-mod dm-crypt; do
  addmod "$m"
done
printf '%s\n' "${MOD_ORDER[@]}" > "$IR/modules/load.order"
echo "[modules] $(tr '\n' ' ' < "$IR/modules/load.order")"

cat > "$IR/init" <<'INIT'
#!/bin/sh
export PATH=/bin
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
mount -t securityfs securityfs /sys/kernel/security 2>/dev/null
mount -t tmpfs tmpfs /run 2>/dev/null
mkdir -p /run/cryptsetup /run/lock

while read -r m; do
  [ -n "$m" ] && insmod /modules/$m.ko 2>/dev/null
done < /modules/load.order

mount -t 9p -o trans=virtio,version=9p2000.L,ro nixstore /nix/store \
  || echo "SEALED-STATE-FAIL: nixstore"
mount -t 9p -o trans=virtio,version=9p2000.L,rw outshare /out \
  || echo "SEALED-STATE-FAIL: outshare"

echo "SEALED-STATE-BEGIN"
TOOLS=@TOOLS@
CRYPTSETUP=@CRYPTSETUP@
export PATH=$TOOLS:$PATH
export TPM2TOOLS_TCTI=device:/dev/tpmrm0
# There is no udev in this initramfs. Without this, libdevmapper waits
# for a cookie nothing will ever release and every mapping hangs.
export DM_DISABLE_UDEV=1

PHASE=$(cat /out/phase 2>/dev/null)
FALLBACK=$(cat /out/fallback 2>/dev/null)
R=/out/report-$PHASE.txt
: > $R
say() { echo "$*" >> $R; }

say "phase=$PHASE"
say "pcr11=$(cat /sys/class/tpm/tpm0/pcr-sha256/11 2>/dev/null)"
say "pcr7=$(cat /sys/class/tpm/tpm0/pcr-sha256/7 2>/dev/null)"
say "cmdline=$(cat /proc/cmdline 2>/dev/null)"
cp /sys/kernel/security/tpm0/binary_bios_measurements \
   /out/eventlog-$PHASE.bin 2>/dev/null || say "eventlog=absent"

VAR_DEV=/dev/vda
HOME_DEV=/dev/vdb
devfor() { if [ "$1" = var ]; then echo $VAR_DEV; else echo $HOME_DEV; fi; }
RECOVERY='recovery-key-not-a-secret-this-is-a-negative-control'

cd /tmp
tpm2_createprimary -C o -g sha256 -G ecc -c prim.ctx >/out/primary-$PHASE.log 2>&1
say "primary_rc=$?"

# ---------------------------------------------------------------- sealing
# The policy is TPM2_PolicyPCR over sha256:11 alone. Register 11 is the
# one the stub extends with the image's own sections, so a policy over it
# says exactly "the image that is running is the image this was sealed
# for" and nothing else -- it does not also pin the firmware build or the
# variable store, which registers 0-7 would.
#
# The attributes are spelled out rather than defaulted. An object that
# still permitted its authorisation VALUE to release it would open with
# no policy satisfied at all, and every policy above it would be theatre.
SEAL_ATTRS="fixedtpm|fixedparent|adminwithpolicy|noda"

seal_live() {   # $1 = slot letter, $2 = key file
  rm -f trial.ctx policy.$1
  tpm2_startauthsession -S trial.ctx                >/dev/null 2>&1
  tpm2_policypcr -S trial.ctx -l sha256:11 -L policy.$1 \
                                                    >/out/trial-$1-$PHASE.log 2>&1
  tpm2_flushcontext trial.ctx                       >/dev/null 2>&1
  cp policy.$1 /out/policy-$1.bin
  tpm2_create -C prim.ctx -i "$2" -u /out/seal-$1.pub -r /out/seal-$1.priv \
      -L policy.$1 -a "$SEAL_ATTRS"                 >/out/create-$1-$PHASE.log 2>&1
  say "seal_${1}_rc=$?"
  say "seal_${1}_source=live-register"
}

seal_for_supplied_value() {   # $1 = slot letter, $2 = key file, $3 = raw value file
  rm -f trial.ctx policy.$1
  # A trial session evaluated against a SUPPLIED register value rather
  # than the live one. This is what makes a generation switch possible at
  # all: the machine seals for a boot that has not happened yet.
  tpm2_startauthsession -S trial.ctx                >/dev/null 2>&1
  tpm2_policypcr -S trial.ctx -l sha256:11 -f "$3" -L policy.$1 \
                                                    >/out/trial-$1-$PHASE.log 2>&1
  tpm2_flushcontext trial.ctx                       >/dev/null 2>&1
  cp policy.$1 /out/policy-$1.bin
  tpm2_create -C prim.ctx -i "$2" -u /out/seal-$1.pub -r /out/seal-$1.priv \
      -L policy.$1 -a "$SEAL_ATTRS"                 >/out/create-$1-$PHASE.log 2>&1
  say "seal_${1}_rc=$?"
  say "seal_${1}_source=supplied-value"
}

esys_rc() { sed -n 's/.*Esys_Unseal(\(0x[0-9A-Fa-f]*\)).*/\1/p' "$1" | head -1; }

try_unseal() {   # $1 = slot letter, $2 = destination key file
  local lrc urc nrc
  rm -f seal.$1.ctx sess.$1.ctx "$2" noauth.$1
  if [ ! -f /out/seal-$1.pub ]; then
    say "unseal_${1}_rc=-1"
    say "unseal_${1}_tpm_rc=absent"
    say "unseal_${1}_noauth_rc=-1"
    say "unseal_${1}_noauth_tpm_rc=absent"
    return 1
  fi
  tpm2_load -C prim.ctx -u /out/seal-$1.pub -r /out/seal-$1.priv \
      -c seal.$1.ctx -n /out/seal-$1.name       >/out/load-$1-$PHASE.log 2>&1
  lrc=$?
  say "load_${1}_rc=$lrc"

  # The no-session probe, run on every cycle including the ones where the
  # policy is satisfied: an object that opens here is one whose policy
  # never had to be met.
  tpm2_unseal -c seal.$1.ctx -o noauth.$1          >/out/noauth-$1-$PHASE.log 2>&1
  nrc=$?
  say "unseal_${1}_noauth_rc=$nrc"
  say "unseal_${1}_noauth_tpm_rc=$(esys_rc /out/noauth-$1-$PHASE.log)"

  tpm2_startauthsession --policy-session -S sess.$1.ctx >/dev/null 2>&1
  tpm2_policypcr -S sess.$1.ctx -l sha256:11       >/out/policyrun-$1-$PHASE.log 2>&1
  say "policypcr_${1}_rc=$?"
  tpm2_unseal -p session:sess.$1.ctx -c seal.$1.ctx -o "$2" \
                                                   >/out/unseal-$1-$PHASE.log 2>&1
  urc=$?
  tpm2_flushcontext sess.$1.ctx                    >/dev/null 2>&1
  say "unseal_${1}_rc=$urc"
  say "unseal_${1}_tpm_rc=$(esys_rc /out/unseal-$1-$PHASE.log)"
  return $urc
}

# ---------------------------------------------------------------- volumes
# The open attempt is UNCONDITIONAL. "Did it stay locked" has to be asked
# of an attempt that really reached the LUKS key slots, not of a step that
# was skipped because the unseal already failed -- otherwise the answer is
# about control flow in this script rather than about the volume. When no
# key was recovered the attempt is made with 32 zero bytes, which is a
# wrong key rather than an absent one.
prepare_key() {   # $1 = key file -> echoes the source
  if [ -s "$1" ]; then echo unsealed; return; fi
  if [ "$FALLBACK" = "1" ]; then
    printf '%s\n' "$RECOVERY" > "$1"; echo recovery; return
  fi
  dd if=/dev/zero of="$1" bs=32 count=1 2>/dev/null
  echo zero-filled
}

open_volumes() {   # $1 = key file
  local v dev rc src
  src=$(prepare_key "$1")
  say "open_key_source=$src"
  for v in var home; do
    dev=$(devfor $v)
    $CRYPTSETUP open --type luks --batch-mode --key-file "$1" \
        "$dev" reproos-state-$v                    >/out/open-$v-$PHASE.log 2>&1
    rc=$?
    say "open_${v}_rc=$rc"
  done
}

report_volumes() {
  local v dev
  say "mapper_entries=$(ls /dev/mapper 2>/dev/null | grep -v '^control$' | tr '\n' ',')"
  for v in var home; do
    dev=$(devfor $v)
    say "luks_uuid_${v}=$($CRYPTSETUP luksUUID "$dev" 2>/dev/null)"
    if $CRYPTSETUP status reproos-state-$v >/tmp/st-$v 2>&1; then
      say "status_${v}=active"
    else
      say "status_${v}=inactive"
    fi
    if [ -e /dev/mapper/reproos-state-$v ]; then
      say "marker_${v}=$(dd if=/dev/mapper/reproos-state-$v bs=64 count=1 \
            2>/dev/null | tr -d '\000')"
    else
      say "marker_${v}=-"
    fi
    # What the block device itself carries, with no mapping in the way:
    # a LUKS2 signature at the front, and ciphertext 16 MiB in, where the
    # marker sits if the volume is readable at all.
    say "raw_magic_${v}=$(dd if=$dev bs=6 count=1 2>/dev/null \
          | od -v -An -tx1 | tr -d ' \n')"
    say "raw_data_${v}=$(dd if=$dev bs=64 count=1 skip=262144 2>/dev/null \
          | od -v -An -tx1 | tr -d ' \n')"
  done
}

close_volumes() {
  local v
  for v in var home; do
    $CRYPTSETUP close reproos-state-$v >/dev/null 2>&1 || true
  done
}

case "$PHASE" in
  enroll)
    dd if=/dev/urandom of=/tmp/key.bin bs=32 count=1 2>/dev/null
    say "key_bytes=$(wc -c < /tmp/key.bin)"
    for v in var home; do
      dev=$(devfor $v)
      $CRYPTSETUP luksFormat --type luks2 --batch-mode \
        --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
        --cipher aes-xts-plain64 --key-size 512 \
        --key-file /tmp/key.bin "$dev"             >/out/format-$v.log 2>&1
      say "format_${v}_rc=$?"
      if [ "$FALLBACK" = "1" ]; then
        printf '%s\n' "$RECOVERY" > /tmp/recovery.bin
        $CRYPTSETUP luksAddKey --batch-mode \
          --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
          --key-file /tmp/key.bin "$dev" /tmp/recovery.bin \
                                                   >/out/addkey-$v.log 2>&1
        say "addkey_${v}_rc=$?"
      fi
      $CRYPTSETUP luksDump "$dev"                  >/out/luksdump-$v.txt 2>&1
    done
    open_volumes /tmp/key.bin
    for v in var home; do
      if [ -e /dev/mapper/reproos-state-$v ]; then
        dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -v -An -tx1 \
          | tr -d ' \n' > /out/marker-$v.hex
        dd if=/out/marker-$v.hex of=/dev/mapper/reproos-state-$v \
           bs=64 count=1 conv=notrunc 2>/dev/null
        sync
      fi
    done
    report_volumes
    seal_live a /tmp/key.bin
    try_unseal a /tmp/verify.key || true
    close_volumes
    ;;
  reboot)
    try_unseal a /tmp/key.out || true
    open_volumes /tmp/key.out
    report_volumes
    close_volumes
    ;;
  reseal)
    try_unseal a /tmp/key.out || true
    open_volumes /tmp/key.out
    report_volumes
    say "next_generation_pcr11=$(cat /out/next-generation.pcr11 2>/dev/null)"
    seal_for_supplied_value b /tmp/key.out /out/next-generation.pcr11.bin
    # Sealed for a boot that has not happened: it must NOT open here.
    try_unseal b /tmp/premature.key || true
    close_volumes
    ;;
  switch)
    try_unseal a /tmp/olda.key || true
    try_unseal b /tmp/key.out || true
    open_volumes /tmp/key.out
    report_volumes
    close_volumes
    ;;
  tamper)
    try_unseal a /tmp/key.out || true
    try_unseal b /tmp/keyb.out || true
    open_volumes /tmp/key.out
    report_volumes
    close_volumes
    ;;
  *)
    say "unknown_phase=1"
    ;;
esac

say "end=1"
sync
echo "SEALED-STATE-DONE"
poweroff -f
INIT
sed -i "s|@TOOLS@|$TOOLS|; s|@CRYPTSETUP@|$CRYPTSETUP|" "$IR/init"
chmod +x "$IR/init"

# Deterministic: a fixed mtime on every member and a sorted member list,
# so the three images differ in EXACTLY the section their command lines
# put them in and in no other.
find "$IR" -exec touch -h -d @0 {} + 2>/dev/null || true
( cd "$IR" && find . -print0 | LC_ALL=C sort -z |
    cpio -o -H newc --quiet --reproducible -0 ) > "$WORK/initrd.img"

# ---------------------------------------------------------------- images
build_uki() {   # $1 = letter, $2 = command line
  SOURCE_DATE_EPOCH=1700000000 "$UKI_TOOL" assemble \
    --stub "$STUB" --kernel "$KERNEL" --initrd "$WORK/initrd.img" \
    --cmdline "$2" --uname "6.12.85" --os-release-version "0" \
    --source-date-epoch 1700000000 --out "$WORK/uki-$1.efi" \
    --manifest "$WORK/out/uki-$1.json" --digest-out "$WORK/out/uki-$1.sha256" \
    --cmdline-out "$WORK/out/uki-$1.cmdline"
  "$MEASURE" attest expect --uki "$WORK/uki-$1.efi" \
    --config-fingerprint sealed-state \
    --verity-root-hash 5555555555555555555555555555555555555555555555555555555555555555 \
    --verity-image-digest sha256:0000000000000000000000000000000000000000000000000000000000000000 \
    --backend tpm > "$WORK/out/expect-$1.json"
  sed -n 's/.*"pcr11": "\([0-9a-f]*\)".*/\1/p' "$WORK/out/expect-$1.json" \
    | head -1 | tr -d '\n' > "$WORK/out/predicted-$1.pcr11"
  sed -n 's/.*"eventLogTemplate": "\(.*\)".*/\1/p' "$WORK/out/expect-$1.json" \
    | head -1 > "$WORK/out/template-$1.txt"
}
build_uki a "$CMDLINE_A"
build_uki b "$CMDLINE_B"
build_uki t "$CMDLINE_T"

# What the running generation A is handed so it can seal for B: the
# register value B's image bytes determine, as text and as the raw 32
# bytes a trial session evaluates. Both come out of the SAME
# `attest expect` answer, so the number the guest seals under and the
# number a reader checks are one number.
cp "$WORK/out/predicted-b.pcr11" "$WORK/out/next-generation.pcr11"
python3 - "$WORK/out/next-generation.pcr11" "$WORK/out/next-generation.pcr11.bin" <<'PY'
import sys
hexv = open(sys.argv[1]).read().strip()
assert len(hexv) == 64, hexv
open(sys.argv[2], 'wb').write(bytes.fromhex(hexv))
PY
printf '%s' "$FALLBACK" > "$WORK/out/fallback"

# ---------------------------------------------------------------- disks
# The two encrypted volumes. They are created EMPTY and are never touched
# by the host again: everything that happens to them happens inside a
# guest, so "the volume is locked" is a statement about a block device
# this script has no key for either.
truncate -s 64M "$WORK/state-var.img"
truncate -s 64M "$WORK/state-home.img"
truncate -s 96M "$WORK/esp.img"
mkfs.vfat -n ESP -F 32 "$WORK/esp.img" >/dev/null
export MTOOLS_SKIP_CHECK=1
mmd -i "$WORK/esp.img" ::/EFI ::/EFI/BOOT
cp "$OVMF/FV/OVMF_VARS.fd" "$WORK/vars.fd"; chmod +w "$WORK/vars.fd"

install_generation() {   # $1 = letter
  mdel -i "$WORK/esp.img" ::/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true
  mcopy -i "$WORK/esp.img" "$WORK/uki-$1.efi" ::/EFI/BOOT/BOOTX64.EFI
}

# ---------------------------------------------------------------- teardown
SWTPM_PID=""
cleanup() {
  if [ -n "$SWTPM_PID" ]; then
    kill "$SWTPM_PID" 2>/dev/null || true
    wait "$SWTPM_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK/tpmstate" "$WORK/swtpm.sock" "$WORK/swtpm.sock.ctrl"
}
trap cleanup EXIT

run_cycle() {   # $1 = cycle name, $2 = image letter
  local phase=$1 image=$2 i
  echo "[cycle] $phase on generation $image"
  printf '%s' "$phase" > "$WORK/out/phase"
  install_generation "$image"

  "$SWTPM/swtpm" socket --tpmstate dir="$WORK/tpmstate" \
    --ctrl type=unixio,path="$WORK/swtpm.sock" \
    --tpm2 --flags not-need-init,startup-clear \
    >>"$WORK/swtpm.log" 2>&1 &
  SWTPM_PID=$!
  for i in $(seq 1 100); do [ -S "$WORK/swtpm.sock" ] && break; sleep 0.1; done
  if [ ! -S "$WORK/swtpm.sock" ]; then
    echo "SWTPM DID NOT START:"; cat "$WORK/swtpm.log"; exit 1
  fi

  timeout 300 qemu-system-x86_64 \
    -machine q35,smm=on,accel=kvm:tcg -m 2048 -smp 2 -no-reboot \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF/FV/OVMF_CODE.fd" \
    -drive if=pflash,format=raw,unit=1,file="$WORK/vars.fd" \
    -drive file="$WORK/esp.img",format=raw,if=none,id=esp0 \
    -device ide-hd,drive=esp0,bus=ide.0,bootindex=0 \
    -drive file="$WORK/state-var.img",format=raw,if=none,id=sv0 \
    -device virtio-blk-pci,drive=sv0,serial=statevar \
    -drive file="$WORK/state-home.img",format=raw,if=none,id=sh0 \
    -device virtio-blk-pci,drive=sh0,serial=statehome \
    -device virtio-rng-pci \
    -chardev socket,id=chrtpm,path="$WORK/swtpm.sock" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-crb,tpmdev=tpm0 \
    -virtfs local,path=/nix/store,mount_tag=nixstore,security_model=none,readonly=on \
    -virtfs local,path="$WORK/out",mount_tag=outshare,security_model=none \
    -debugcon "file:$WORK/ovmf-$phase.log" -global isa-debugcon.iobase=0x402 \
    -display none -monitor none -serial "file:$WORK/console-$phase.log" \
    >"$WORK/qemu-$phase.err" 2>&1 </dev/null || true

  kill "$SWTPM_PID" 2>/dev/null || true
  wait "$SWTPM_PID" 2>/dev/null || true
  SWTPM_PID=""
  rm -f "$WORK/swtpm.sock" "$WORK/swtpm.sock.ctrl"

  if ! grep -q SEALED-STATE-DONE "$WORK/console-$phase.log" 2>/dev/null; then
    echo "[cycle] $phase: the guest did not reach the end of its init" >&2
    tail -40 "$WORK/console-$phase.log" 2>/dev/null >&2 || true
  fi
}

for phase in $CYCLES; do
  case "$phase" in
    enroll|reboot|reseal) run_cycle "$phase" a ;;
    switch)               run_cycle "$phase" b ;;
    tamper)               run_cycle "$phase" t ;;
    *) echo "unknown cycle: $phase" >&2; exit 64 ;;
  esac
done

echo "=== artifacts:"; ls -la "$WORK/out"

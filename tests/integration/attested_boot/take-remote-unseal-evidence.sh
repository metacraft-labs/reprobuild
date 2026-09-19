#!/usr/bin/env bash
#
# Take one machine's evidence about state volumes it has no key for.
#
# This is the fourth harness beside the three already here, and it is the
# inverse of the sealing one. There, a machine's own TPM held the key and
# the question was whether it would still release it after the boot
# changed. Here THE MACHINE HAS NO KEY AT ALL -- no TPM, no sealed
# object, nothing on its disk and nothing in its initramfs -- and the
# question is what happens when the party that does hold it says no.
#
# One run is ONE MACHINE across THREE POWER CYCLES. Two LUKS2 volumes on
# virtio block devices persist across all three; nothing else does. A
# broker runs on the host, in its own process, and the guest reaches it
# outbound over QEMU's user-mode network.
#
#   cycle    broker         what the guest is asked to do
#   -------  -------------  --------------------------------------------
#   enroll   releasing      attest, receive the volume key, CREATE both
#                           LUKS2 volumes with it, put a root filesystem
#                           inside the first one carrying an `init` and a
#                           SENTINEL, and power off
#   unseal   releasing      attest, receive the key, open both volumes,
#                           and hand off to the `init` inside the
#                           encrypted one
#   refuse   REFUSING       attest, be turned down, and not come up
#
# WHAT MAKES "THE BOOT FAILED" A MEASUREMENT RATHER THAN A WORD. The
# `init` that continues the boot lives INSIDE the encrypted volume, and
# so does the sentinel it prints. Neither is in the initramfs, neither is
# in the kernel, and after the `enroll` cycle neither is anywhere the
# guest can read except through a mapping it has no key to create. So
# "the sentinel is on the console" and "the encrypted root filesystem
# executed" are the same statement, and the harness checks the initramfs
# for the sentinel to show it is not available any other way.
#
# THE TWO CLAIMS OF THE REFUSAL CYCLE ARE SEPARATE AND ARE MEASURED
# SEPARATELY:
#
#   * the broker refused and the boot did not continue;
#   * the volumes stayed locked.
#
#   take-remote-unseal-evidence.sh <workdir>
#
# Environment (each is named out loud when missing; this harness never
# skips, because a run that quietly did nothing is worse than one that
# failed):
#
#   UNSEAL_KERNEL      the kernel to boot.
#   UNSEAL_KMOD        its module tree.
#   UNSEAL_BUSYBOX     a STATIC shell and core utilities. Check
#                      `busybox --list | wc -l` before blaming anything
#                      else: several static busybox derivations in a Nix
#                      store report an EMPTY applet list, and an
#                      initramfs built from one answers every command
#                      with `applet not found`.
#   UNSEAL_AGENT       the attestation-agent binary, which carries the
#                      `remote-unseal` client. Dynamically linked is fine
#                      and is the point: /nix/store is mounted in the
#                      guest, so the binary under test is the one this
#                      repository builds.
#   UNSEAL_BROKER      the host-side broker binary.
#   UNSEAL_CRYPTSETUP  the cryptsetup binary the guest runs.
#   UNSEAL_MKFS        mkfs.ext4, run IN THE GUEST on the opened mapping.
#
# Optional:
#
#   UNSEAL_LOCAL_KEY_FALLBACK=1
#       Plant the volume key in the initramfs as `/fallback.key` and have
#       the guest fall back to it whenever the client comes back
#       empty-handed. THIS IS THE ARRANGEMENT REMOTE UNSEALING REMOVES --
#       a machine with a locally cached key -- and running it produces
#       the negative control in which the broker refuses with the SAME
#       status and the volumes open anyway. The gate feeds both records
#       to the same predicates: the refusal check must still be TRUE and
#       the locked check must be FALSE. Only `enroll` and `refuse` are
#       run under it. NEVER use this flag for a capture meant to
#       represent correct behaviour.
#
#   UNSEAL_CYCLES="enroll unseal refuse"
#       Run a subset, in the given order.
#
# The guest's init is IDENTICAL in every cycle and is told which cycle it
# is over the shared directory. That is not a convenience: the initramfs
# is one of the things whose contents this experiment holds fixed, and an
# init that branched on the cycle would make the three boots three
# different machines.
#
# WHAT THIS HARNESS DELIBERATELY DOES NOT DO, stated here rather than
# left for a reader to find out:
#
#   * There is NO unified kernel image, NO firmware, NO TPM and NO
#     measured boot. The guest boots straight into an initramfs and its
#     root of trust is a SOFTWARE one; the broker's policy admits the
#     tier that has none and the broker's own record says
#     `accepted-without-a-root-of-trust` out loud. Binding a release to
#     hardware evidence is a different question asked by a different
#     gate. What this one asks is what a refusal does to a disk.
#   * The transport is plaintext HTTP over QEMU's user-mode network.
#
# Everything the run creates is torn down unconditionally, including on
# the failure paths. The evidence directory is left, because it is the
# output.
set -euo pipefail

WORK="${1:?workdir}"

need() {
  local name=$1 value=${2:-}
  if [ -z "$value" ]; then
    echo "take-remote-unseal-evidence: $name is not set. This harness" >&2
    echo "  boots a real machine, drives a real broker over a real" >&2
    echo "  socket and creates real LUKS2 volumes; it names what it" >&2
    echo "  could not find rather than reporting a skip, because a run" >&2
    echo "  that quietly did nothing is worse than one that failed." >&2
    exit 69
  fi
  printf '%s' "$value"
}

KERNEL=$(need UNSEAL_KERNEL "${UNSEAL_KERNEL:-}")
KMOD=$(need UNSEAL_KMOD "${UNSEAL_KMOD:-}")
BUSYBOX=$(need UNSEAL_BUSYBOX "${UNSEAL_BUSYBOX:-}")
AGENT=$(need UNSEAL_AGENT "${UNSEAL_AGENT:-}")
BROKER=$(need UNSEAL_BROKER "${UNSEAL_BROKER:-}")
CRYPTSETUP=$(need UNSEAL_CRYPTSETUP "${UNSEAL_CRYPTSETUP:-}")
MKFS=$(need UNSEAL_MKFS "${UNSEAL_MKFS:-}")

# The client names its volume opener by an absolute path and refuses a
# bare name, so a relative value here would fail inside the guest where
# the message is hardest to see. It fails out here instead.
for tool in "$CRYPTSETUP" "$MKFS"; do
  case "$tool" in
    /*) ;;
    *) echo "take-remote-unseal-evidence: $tool is not an absolute path;" >&2
       echo "  the guest resolves nothing through PATH." >&2
       exit 69 ;;
  esac
done

FALLBACK="${UNSEAL_LOCAL_KEY_FALLBACK:-0}"
DEFAULT_CYCLES="enroll unseal refuse"
if [ "$FALLBACK" = "1" ]; then DEFAULT_CYCLES="enroll refuse"; fi
CYCLES="${UNSEAL_CYCLES:-$DEFAULT_CYCLES}"

SECRET_NAME="state-volume-key"
GENERATION="remote-unseal-harness-gen-1"
CONFIG_FINGERPRINT="reproos-remote-unseal-harness"
VERITY_ROOT_HASH=0000000000000000000000000000000000000000000000000000000000000000
VOLUME_MIB=160

if ldd "$BUSYBOX" >/dev/null 2>&1; then
  echo "take-remote-unseal-evidence: UNSEAL_BUSYBOX must be statically" >&2
  echo "  linked; $BUSYBOX is not. Nothing is mounted when init starts," >&2
  echo "  so a dynamic shell cannot find its own interpreter." >&2
  exit 69
fi
if [ "$("$BUSYBOX" --list 2>/dev/null | wc -l)" -lt 50 ]; then
  echo "take-remote-unseal-evidence: $BUSYBOX reports an empty applet" >&2
  echo "  list. An initramfs built from it comes up and answers every" >&2
  echo "  command with 'applet not found', which reads like a broken" >&2
  echo "  script and is not one." >&2
  exit 69
fi

mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
OUT="$WORK/out"
IR="$WORK/initramfs"
rm -rf "$OUT" "$IR" "$WORK/broker-out"
mkdir -p "$OUT" "$WORK/broker-out" \
         "$IR"/{bin,modules,proc,sys,dev,run,tmp,mnt,sysroot,out,nix/store}

# ---------------------------------------------------------------------
# The two tokens
#
# The KEY is the volume passphrase. It is drawn here, on the host, handed
# to the broker, and never written anywhere the guest can read it -- in
# the honest cycles it reaches the guest only as ciphertext and only ever
# exists there on one process's standard input.
#
# The SENTINEL is baked into the root filesystem the guest builds inside
# the encrypted volume, and the file that carries it to the guest is
# DELETED after the enrolling cycle. From then on it exists in exactly
# one place: inside ciphertext.
#
# Both are 64 printable hexadecimal characters, which makes every search
# below auditable by hand.
# ---------------------------------------------------------------------
VOLUME_KEY=$(head -c 32 /dev/urandom | od -v -An -tx1 | tr -d ' \n')
SENTINEL=$(head -c 32 /dev/urandom | od -v -An -tx1 | tr -d ' \n')
SENTINEL_SHA256=$(printf '%s' "$SENTINEL" | sha256sum | cut -d' ' -f1)
printf '%s' "$VOLUME_KEY" > "$WORK/volume-key.txt"
chmod 600 "$WORK/volume-key.txt"
printf '%s' "$FALLBACK" > "$OUT/fallback"

cat > "$WORK/policy.toml" <<'POLICY'
schema = "reproos.attestation-policy.v1"

# The guest has no hardware root of trust, so this policy admits the tier
# that has none and says so twice, which is the only way the parser lets
# it be said. Whether a release happens under it is then the BROKER's
# separate opt-in -- and the refusing cycle is that opt-in withheld,
# which is a shipped rule declining rather than a branch written to
# decline.
[accept]
tiers = ["mock"]
backends = ["mock"]
allow_mock = true

[measurements]
manifests = []
require_certificates = false

[freshness]
max_challenge_age_seconds = 300
require_challenge = true
POLICY

# ---------------------------------------------------------------------
# The init that lives INSIDE the encrypted volume
#
# It is written here, handed to the guest through the shared directory
# for the enrolling cycle only, and the copy in that directory is removed
# before any later cycle boots.
# ---------------------------------------------------------------------
cat > "$WORK/rootfs-init" <<ROOTFS
#!/bin/sh
# This file exists only inside an encrypted volume. Reaching this line
# means a key was released, a mapping was created and a filesystem was
# mounted; there is no other way for these bytes to run.
export PATH=/bin
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sys /sys 2>/dev/null
mount -t devtmpfs dev /dev 2>/dev/null
CYCLE=\$(cat /out/cycle 2>/dev/null)
R=/out/rootfs-\$CYCLE.txt
: > \$R
echo "cycle=\$CYCLE" >> \$R
# The DIGEST, not the sentinel. The shared directory is readable by every
# later boot, so a record carrying the sentinel verbatim would put it back
# somewhere an unencrypted machine can read -- which is precisely the
# property this experiment is measuring.
echo "rootfs_sentinel_sha256=$SENTINEL_SHA256" >> \$R
echo "rootfs_marker=\$(cat /state-marker 2>/dev/null)" >> \$R
# WHICH DEVICE THIS ROOT FILESYSTEM CAME OFF. It has to be the
# device-mapper node, because that is the only way these bytes could
# have been read at all.
# The bytes of this very file, as it sits inside the encrypted volume.
# It is the one thing here that is a statement about WHAT ran rather than
# about what it found, and the host knows what to expect because it wrote
# the file.
echo "rootfs_init_sha256=\$(sha256sum /init | cut -d' ' -f1)" >> \$R
echo "end=1" >> \$R
sync
echo "REMOTE-UNSEAL-ROOTFS $SENTINEL"
poweroff -f
ROOTFS
chmod +x "$WORK/rootfs-init"

# ---------------------------------------------------------------------
# The initramfs
# ---------------------------------------------------------------------
cp "$BUSYBOX" "$IR/bin/busybox"
chmod +x "$IR/bin/busybox"
# The client goes IN the initramfs; its shared libraries come from the
# 9p-mounted store. That is the point of not building a static one: the
# binary under test is the binary this repository builds.
cp "$AGENT" "$IR/bin/attestation-agent"
chmod +x "$IR/bin/attestation-agent"
for ap in sh mount umount cp cat echo ls mkdir rm insmod sync poweroff sleep \
          dd printf od tr sed grep head cut wc env chmod ln true false \
          sha256sum awk ifconfig ip route stat date kill switch_root \
          mkdir touch; do
  ln -sf busybox "$IR/bin/$ap"
done

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
# `cbc` before `dm-crypt`: dm-crypt depends on encrypted-keys, which
# registers a cbc(aes) transform at init time and gives up if the
# template is not there yet. The symptom is `crypt: unknown target type`,
# which reads like a missing dm-crypt module and is not one. There is no
# modprobe in this initramfs, so this order is the only thing deciding it.
for m in netfs 9pnet virtio_ring virtio virtio_pci_legacy_dev \
         virtio_pci_modern_dev virtio_pci 9pnet_virtio 9p virtio_blk \
         virtio_net net_failover failover rng-core virtio-rng \
         cbc xts af_alg algif_skcipher algif_hash \
         dm-mod dm-crypt \
         crc32c-intel crc32c_generic mbcache jbd2 ext4; do
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
mount -t tmpfs tmpfs /run
mkdir -p /run/cryptsetup /run/lock /tmp /mnt /sysroot

while read -r m; do
  [ -n "$m" ] && insmod /modules/$m.ko 2>/dev/null
done < /modules/load.order

mount -t 9p -o trans=virtio,version=9p2000.L,ro nixstore /nix/store \
  || echo "REMOTE-UNSEAL-FAIL: nixstore"
mount -t 9p -o trans=virtio,version=9p2000.L,rw outshare /out \
  || echo "REMOTE-UNSEAL-FAIL: outshare"

echo "REMOTE-UNSEAL-BEGIN"
AGENT=/bin/attestation-agent
CRYPTSETUP=@CRYPTSETUP@
MKFS=@MKFS@
GENERATION=@GENERATION@
CONFIG_FINGERPRINT=@CONFIG_FINGERPRINT@
VERITY_ROOT_HASH=@VERITY_ROOT_HASH@
SECRET_NAME=@SECRET_NAME@
# There is no udev in this initramfs. Without this, libdevmapper waits
# for a cookie nothing will ever release and every mapping hangs.
export DM_DISABLE_UDEV=1

CYCLE=$(cat /out/cycle 2>/dev/null)
BROKER=$(cat /out/broker-url 2>/dev/null)
R=/out/report-$CYCLE.txt
: > $R
say() { echo "$*" >> $R; }

say "cycle=$CYCLE"
say "broker_url_present=$([ -n "$BROKER" ] && echo 1 || echo 0)"

ifconfig lo 127.0.0.1 netmask 255.0.0.0 up 2>/dev/null
ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up 2>/dev/null
route add default gw 10.0.2.2 2>/dev/null
say "eth0_up=$(ifconfig eth0 2>/dev/null | grep -c 'inet addr:10.0.2.15')"

# NO LOCAL SEALING, read off the machine rather than asserted about it.
# There is no TPM, no sealed object, and -- in an honest run -- no key
# file anywhere in this initramfs. The only thing that can unlock these
# volumes is the answer to a question asked over a network.
say "tpm_devices=$(ls /dev/tpm0 /dev/tpmrm0 2>/dev/null | wc -l)"
say "tpm_class_entries=$(ls /sys/class/tpm 2>/dev/null | wc -l)"
say "local_key_files=$(ls /fallback.key 2>/dev/null | wc -l)"

ROOT_DEV=/dev/vda
HOME_DEV=/dev/vdb
ROOT_MAP=reproos-state-root
HOME_MAP=reproos-state-home
devfor() { if [ "$1" = root ]; then echo $ROOT_DEV; else echo $HOME_DEV; fi; }
mapfor() { if [ "$1" = root ]; then echo $ROOT_MAP; else echo $HOME_MAP; fi; }

client() {   # $1 = action -> echoes the exit status
  $AGENT remote-unseal --action=$1 --broker="$BROKER" \
    --name=$SECRET_NAME --generation=$GENERATION \
    --config-fingerprint=$CONFIG_FINGERPRINT \
    --verity-root-hash=$VERITY_ROOT_HASH \
    --volume=$ROOT_DEV:$ROOT_MAP --volume=$HOME_DEV:$HOME_MAP \
    --cryptsetup=$CRYPTSETUP --report=/out/client-$CYCLE-$1.txt \
    --timeout-seconds=30 --wait-seconds=90 \
    >> /out/client-$CYCLE.log 2>&1
  echo $?
}

install_rootfs() {   # $1 = volume name, $2 = 1 to install an init
  local v=$1 map
  map=$(mapfor $v)
  [ -e /dev/mapper/$map ] || return 0
  $MKFS -q -F -L reproos$v /dev/mapper/$map >/out/mkfs-$v.log 2>&1
  say "mkfs_${v}_rc=$?"
  mkdir -p /mnt/$v
  mount -t ext4 /dev/mapper/$map /mnt/$v || { say "enroll_mount_${v}_rc=1"; return 0; }
  say "enroll_mount_${v}_rc=0"
  dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -v -An -tx1 \
    | tr -d ' \n' > /mnt/$v/state-marker
  cp /mnt/$v/state-marker /out/marker-$v.hex
  if [ "$2" = 1 ]; then
    mkdir -p /mnt/$v/bin /mnt/$v/proc /mnt/$v/sys /mnt/$v/dev /mnt/$v/out
    cp /bin/busybox /mnt/$v/bin/busybox
    chmod +x /mnt/$v/bin/busybox
    for ap in sh mount cat echo poweroff sync grep ls cut sha256sum; do
      ln -sf busybox /mnt/$v/bin/$ap
    done
    cp /out/rootfs-init /mnt/$v/init
    chmod +x /mnt/$v/init
    say "rootfs_installed=1"
  fi
  sync
  umount /mnt/$v
}

report_volumes() {
  local v dev map
  say "mapper_entries=$(ls /dev/mapper 2>/dev/null | grep -v '^control$' \
        | tr '\n' ',')"
  for v in root home; do
    dev=$(devfor $v); map=$(mapfor $v)
    say "luks_uuid_$v=$($CRYPTSETUP luksUUID $dev 2>/dev/null)"
    if $CRYPTSETUP status $map >/tmp/st-$v 2>&1; then
      say "status_$v=active"
    else
      say "status_$v=inactive"
    fi
    if [ -e /dev/mapper/$map ]; then
      mkdir -p /mnt/read-$v
      if mount -t ext4 -o ro /dev/mapper/$map /mnt/read-$v 2>/dev/null; then
        say "marker_$v=$(cat /mnt/read-$v/state-marker 2>/dev/null)"
        umount /mnt/read-$v
      else
        say "marker_$v=unmountable"
      fi
    else
      say "marker_$v=-"
    fi
    # What the block device itself carries, with no mapping in the way: a
    # LUKS2 signature at the front, and ciphertext 16 MiB in.
    say "raw_magic_$v=$(dd if=$dev bs=6 count=1 2>/dev/null \
          | od -v -An -tx1 | tr -d ' \n')"
    say "raw_data_$v=$(dd if=$dev bs=64 count=1 skip=262144 2>/dev/null \
          | od -v -An -tx1 | tr -d ' \n')"
  done
}

# ---------------------------------------------------------------- the ask
if [ "$CYCLE" = "enroll" ]; then
  say "format_rc=$(client format)"
  say "client_rc=$(client open)"
  install_rootfs root 1
  install_rootfs home 0
else
  say "client_rc=$(client open)"
fi

# ---------------------------------------------------------------- the probe
# The condition is about the DEVICE, not about what the client answered:
# a second `open` on a live mapping fails for a reason that has nothing to
# do with keys. So whenever there is no mapping, an attempt is made that
# really reaches the LUKS key slots, and "the volume stayed locked" is a
# statement about a volume that turned a real attempt away rather than
# about a step this script skipped.
#
# The key that attempt uses is the whole of the negative control. Without
# `/fallback.key` it is 32 zero bytes -- a WRONG key rather than an absent
# one. With it, it is the machine's own locally cached copy of the volume
# key, which is the arrangement remote unsealing removes, and the volumes
# open in spite of the refusal.
if [ -e /dev/mapper/$ROOT_MAP ]; then
  say "probe_ran=0"
  say "probe_key_source=-"
  say "probe_root_rc=-1"
  say "probe_home_rc=-1"
else
  if [ -s /fallback.key ]; then
    cp /fallback.key /tmp/probe.key
    say "probe_key_source=cached-local-key"
  else
    dd if=/dev/zero of=/tmp/probe.key bs=32 count=1 2>/dev/null
    say "probe_key_source=zero-filled"
  fi
  say "probe_ran=1"
  $CRYPTSETUP open --type luks --batch-mode --key-file /tmp/probe.key \
      $ROOT_DEV $ROOT_MAP >/out/probe-root-$CYCLE.log 2>&1
  say "probe_root_rc=$?"
  $CRYPTSETUP open --type luks --batch-mode --key-file /tmp/probe.key \
      $HOME_DEV $HOME_MAP >/out/probe-home-$CYCLE.log 2>&1
  say "probe_home_rc=$?"
fi

report_volumes

# ------------------------------------------------------- the boot continues
# Or does not. The `init` this hands off to is inside the encrypted
# volume; there is no second one and no fallback root.
CONTINUE=0
if [ -e /dev/mapper/$ROOT_MAP ] \
   && mount -t ext4 /dev/mapper/$ROOT_MAP /sysroot 2>/dev/null; then
  say "sysroot_mounted=1"
  if [ -x /sysroot/init ]; then CONTINUE=1; fi
else
  say "sysroot_mounted=0"
fi
say "switch_root_attempted=$CONTINUE"
if [ "$CONTINUE" = 1 ]; then
  say "boot_outcome=handing-off"
else
  say "boot_outcome=failed"
fi
say "end=1"
sync

if [ "$CONTINUE" = 1 ]; then
  mkdir -p /sysroot/out
  mount -o move /out /sysroot/out 2>/dev/null \
    || mount -o bind /out /sysroot/out
  echo "REMOTE-UNSEAL-HANDOFF"
  exec switch_root /sysroot /init
fi

echo "REMOTE-UNSEAL-DONE"
poweroff -f
INIT
python3 - "$IR/init" "$CRYPTSETUP" "$MKFS" "$GENERATION" \
  "$CONFIG_FINGERPRINT" "$VERITY_ROOT_HASH" "$SECRET_NAME" <<'PY'
import sys
path, cryptsetup, mkfs, gen, cfp, verity, name = sys.argv[1:8]
text = open(path).read()
for token, value in (("@CRYPTSETUP@", cryptsetup),
                     ("@MKFS@", mkfs), ("@GENERATION@", gen),
                     ("@CONFIG_FINGERPRINT@", cfp),
                     ("@VERITY_ROOT_HASH@", verity),
                     ("@SECRET_NAME@", name)):
    assert token in text, token
    text = text.replace(token, value)
open(path, "w").write(text)
PY
chmod +x "$IR/init"

# The negative control's whole substance: a copy of the volume key, on
# the machine. See the header.
if [ "$FALLBACK" = "1" ]; then
  printf '%s' "$VOLUME_KEY" > "$IR/fallback.key"
  chmod 600 "$IR/fallback.key"
fi

# The archive is kept UNCOMPRESSED beside the compressed one, and every
# search below reads the uncompressed copy. This is not tidiness: a
# fixed-string grep over a gzip stream finds nothing whatever the stream
# contains, so "the key is not in the initramfs" measured against
# `initrd.img` would be true of an initramfs that carried it in plain
# sight. The negative control run, which really does plant the key in
# there, is what proves the search can see a file inside the archive.
( cd "$IR" && find . -print0 | LC_ALL=C sort -z \
  | cpio --null -o -H newc --quiet > "$WORK/initrd.cpio" )
gzip -9 -c "$WORK/initrd.cpio" > "$WORK/initrd.img"

# ---------------------------------------------------------------------
# The volumes
#
# Created EMPTY and never touched by the host again: everything that
# happens to them happens inside a guest, so "the volume is locked" is a
# statement about a block device this script has no mapping for either.
# ---------------------------------------------------------------------
rm -f "$WORK/state-root.img" "$WORK/state-home.img"
truncate -s "${VOLUME_MIB}M" "$WORK/state-root.img"
truncate -s "${VOLUME_MIB}M" "$WORK/state-home.img"

# Both tokens are searched for at the END of the run, so they are
# searched for NOW as well, in a blank volume and in the initramfs. A
# token already present in a fresh image would make every later result
# meaningless.
precheck() {   # $1 = label, $2 = token, $3 = file
  if grep -q -a -F -- "$2" "$3" 2>/dev/null; then
    echo "take-remote-unseal-evidence: the $1 token is already present" >&2
    echo "  in $3 before anything has run. Refusing to continue: the" >&2
    echo "  search at the end would prove nothing." >&2
    exit 70
  fi
}
precheck key "$VOLUME_KEY" "$WORK/state-root.img"
precheck sentinel "$SENTINEL" "$WORK/state-root.img"
precheck sentinel "$SENTINEL" "$WORK/initrd.cpio"
if [ "$FALLBACK" != "1" ]; then
  precheck key "$VOLUME_KEY" "$WORK/initrd.cpio"
else
  # The control run plants the key in the initramfs on purpose, so the
  # search MUST find it there before anything boots. This is the other
  # direction of the same check and it is what establishes that the
  # honest run's zero is a measurement rather than a blind instrument.
  if ! grep -q -a -F -- "$VOLUME_KEY" "$WORK/initrd.cpio"; then
    echo "take-remote-unseal-evidence: the control run planted the key" >&2
    echo "  in the initramfs and the search cannot find it there. The" >&2
    echo "  honest run's zero would then mean nothing." >&2
    exit 70
  fi
fi

# ---------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------
QEMU_PID=""
BROKER_PID=""
cleanup() {
  if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill -9 "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  if [ -n "$BROKER_PID" ] && kill -0 "$BROKER_PID" 2>/dev/null; then
    kill "$BROKER_PID" 2>/dev/null || true
    wait "$BROKER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------
# One power cycle
# ---------------------------------------------------------------------
run_cycle() {
  local cycle=$1 refusing=$2
  local bout="$WORK/broker-out/$cycle"
  rm -rf "$bout"; mkdir -p "$bout"
  printf '%s' "$cycle" > "$OUT/cycle"
  rm -f "$OUT/report-$cycle.txt" "$OUT/rootfs-$cycle.txt" \
        "$OUT/broker-url"
  echo "[cycle] $cycle (broker: $([ "$refusing" = 1 ] && echo refusing \
        || echo releasing))"

  local requireflag=""
  if [ "$refusing" = "1" ]; then requireflag="--require-root-of-trust"; fi
  "$BROKER" --listen=127.0.0.1:0 --out="$bout" \
    --key-file="$WORK/volume-key.txt" --name="$SECRET_NAME" \
    --policy="$WORK/policy.toml" $requireflag \
    >"$bout/broker.log" 2>&1 &
  BROKER_PID=$!
  local i
  for i in $(seq 1 200); do [ -s "$bout/broker-port" ] && break; sleep 0.1; done
  if [ ! -s "$bout/broker-port" ]; then
    echo "take-remote-unseal-evidence: the broker did not bind a port" >&2
    cat "$bout/broker.log" >&2 || true
    exit 71
  fi
  local port
  port=$(cat "$bout/broker-port")
  # QEMU's user-mode stack maps the host to 10.0.2.2, so an outbound
  # connection from the guest to that address reaches a loopback
  # listener on this machine. The guest is the CLIENT here; nothing is
  # forwarded inbound.
  printf 'http://10.0.2.2:%s' "$port" > "$OUT/broker-url"

  qemu-system-x86_64 \
    -enable-kvm -m 1536 -smp 2 -display none -no-reboot \
    -kernel "$KERNEL" -initrd "$WORK/initrd.img" \
    -append "console=ttyS0 panic=5 rdinit=/init" \
    -serial "file:$WORK/console-$cycle.log" \
    -drive "file=$WORK/state-root.img,format=raw,if=virtio,cache=writeback" \
    -drive "file=$WORK/state-home.img,format=raw,if=virtio,cache=writeback" \
    -fsdev local,id=nixstore,path=/nix/store,security_model=none,readonly=on \
    -device virtio-9p-pci,fsdev=nixstore,mount_tag=nixstore \
    -fsdev "local,id=outshare,path=$OUT,security_model=none" \
    -device virtio-9p-pci,fsdev=outshare,mount_tag=outshare \
    -netdev "user,id=n0" -device virtio-net-pci,netdev=n0 \
    >"$WORK/qemu-$cycle.log" 2>&1 &
  QEMU_PID=$!

  local waited=0
  while kill -0 "$QEMU_PID" 2>/dev/null && [ $waited -lt 420 ]; do
    sleep 2
    waited=$((waited + 2))
  done
  if kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "take-remote-unseal-evidence: the $cycle guest did not power" >&2
    echo "  off within ${waited}s. See $WORK/console-$cycle.log." >&2
    kill -9 "$QEMU_PID" 2>/dev/null || true
  fi
  wait "$QEMU_PID" 2>/dev/null || true
  QEMU_PID=""

  kill "$BROKER_PID" 2>/dev/null || true
  wait "$BROKER_PID" 2>/dev/null || true
  BROKER_PID=""

  if [ ! -s "$OUT/report-$cycle.txt" ]; then
    echo "take-remote-unseal-evidence: the $cycle guest wrote no" >&2
    echo "  report. See $WORK/console-$cycle.log." >&2
    exit 72
  fi
}

SHARE_SENTINEL_LINES=()
for cycle in $CYCLES; do
  # The enrolling cycle is the ONLY one that may see the init that goes
  # inside the volume. Every later boot gets the shared directory without
  # it, so from then on the sentinel exists in exactly one place: inside
  # the ciphertext of the root volume, reachable only through a mapping
  # the guest has no key to create. That is measured rather than
  # asserted: the share is searched immediately before each boot.
  if [ "$cycle" = "enroll" ]; then
    cp "$WORK/rootfs-init" "$OUT/rootfs-init"
  else
    rm -f "$OUT/rootfs-init"
  fi
  # `|| true` because `grep` exits 1 on no match and this script runs
  # under `pipefail`; no match is the expected answer here.
  SHARE_SENTINEL_LINES+=("sentinel_in_share_before_$cycle=$(
    { grep -r -a -l -F -- "$SENTINEL" "$OUT" 2>/dev/null || true; } | wc -l)")
  case "$cycle" in
    enroll) run_cycle enroll 0 ;;
    unseal) run_cycle unseal 0 ;;
    refuse) run_cycle refuse 1 ;;
    *) echo "unknown cycle: $cycle" >&2; exit 64 ;;
  esac
  rm -f "$OUT/rootfs-init"
done

# ---------------------------------------------------------------------
# The searches
#
# Of the raw volume and of the initramfs, by the host, with no guest
# involved.
# ---------------------------------------------------------------------
count_in() {   # $1 = token, $2 = file
  grep -c -a -F -- "$1" "$2" 2>/dev/null || true
}

# "Not found" is worth nothing from a search that finds nothing, and a
# token planted at the easiest place is not a coverage measurement. The
# same token is planted at FIVE offsets -- the very front, a megabyte in,
# the middle, near the end, and the final 64 bytes -- and the search has
# to find it at every one.
coverage() {   # $1 = token, $2 = file -> echoes "<found>/<planted>"
  local token=$1 src=$2 tmp found=0 planted=0 size off
  size=$(wc -c < "$src")
  tmp="$WORK/coverage.img"
  for off in 0 1048576 $((size / 2)) $((size - 1048576)) $((size - 64)); do
    if [ "$off" -lt 0 ] || [ "$off" -gt $((size - 64)) ]; then continue; fi
    cp "$src" "$tmp"
    printf '%s' "$token" | dd of="$tmp" bs=1 seek="$off" conv=notrunc \
      status=none 2>/dev/null
    planted=$((planted + 1))
    if [ "$(count_in "$token" "$tmp")" -gt 0 ]; then found=$((found + 1)); fi
  done
  rm -f "$tmp"
  printf '%s/%s' "$found" "$planted"
}

SEARCH="$OUT/search.txt"
{
  echo "volume_bytes=$(wc -c < "$WORK/state-root.img")"
  echo "initrd_bytes=$(wc -c < "$WORK/initrd.cpio")"
  echo "token_chars=${#VOLUME_KEY}"
  echo "key_sha256=$(printf '%s' "$VOLUME_KEY" | sha256sum | cut -d' ' -f1)"
  echo "sentinel_sha256=$(printf '%s' "$SENTINEL" | sha256sum | cut -d' ' -f1)"
  # What the host wrote into the encrypted volume, so the digest the
  # root filesystem reports of its own `init` can be checked against the
  # file this run put there rather than against itself.
  echo "rootfs_init_sha256=$(sha256sum < "$WORK/rootfs-init" | cut -d' ' -f1)"
  echo "key_hits_root_volume=$(count_in "$VOLUME_KEY" "$WORK/state-root.img")"
  echo "key_hits_home_volume=$(count_in "$VOLUME_KEY" "$WORK/state-home.img")"
  echo "key_hits_initrd=$(count_in "$VOLUME_KEY" "$WORK/initrd.cpio")"
  echo "sentinel_hits_root_volume=$(count_in "$SENTINEL" "$WORK/state-root.img")"
  echo "sentinel_hits_initrd=$(count_in "$SENTINEL" "$WORK/initrd.cpio")"
  echo "sentinel_hits_home_volume=$(count_in "$SENTINEL" "$WORK/state-home.img")"
  echo "key_coverage_root_volume=$(coverage "$VOLUME_KEY" "$WORK/state-root.img")"
  echo "sentinel_coverage_root_volume=$(coverage "$SENTINEL" "$WORK/state-root.img")"
  echo "key_coverage_initrd=$(coverage "$VOLUME_KEY" "$WORK/initrd.cpio")"
  echo "sentinel_coverage_initrd=$(coverage "$SENTINEL" "$WORK/initrd.cpio")"
  # The shared directory is the one writable filesystem the guest keeps
  # across a power cycle, so it is the place a client that wrote its key
  # down would have written it. Counted as FILES containing the token,
  # and the instrument is shown to work on the line below it.
  echo "key_hits_outshare=$({ grep -r -a -l -F -- "$VOLUME_KEY" "$OUT" \
    2>/dev/null || true; } | wc -l)"
  echo "outshare_search_finds_a_planted_file=$(
    mkdir -p "$WORK/planted" && printf '%s' "$VOLUME_KEY" \
      > "$WORK/planted/planted.txt"
    { grep -r -a -l -F -- "$VOLUME_KEY" "$WORK/planted" 2>/dev/null \
      || true; } | wc -l)"
  echo "local_key_fallback=$FALLBACK"
  for line in "${SHARE_SENTINEL_LINES[@]}"; do echo "$line"; done
  for cycle in $CYCLES; do
    echo "console_sentinel_$cycle=$(count_in "$SENTINEL" \
      "$WORK/console-$cycle.log")"
    echo "rootfs_report_$cycle=$([ -s "$OUT/rootfs-$cycle.txt" ] \
      && echo 1 || echo 0)"
    echo "handoff_$cycle=$(count_in "REMOTE-UNSEAL-HANDOFF" \
      "$WORK/console-$cycle.log")"
    echo "key_hits_console_$cycle=$(count_in "$VOLUME_KEY" \
      "$WORK/console-$cycle.log")"
  done
  echo "end=1"
} > "$SEARCH"

rm -rf "$WORK/planted"

echo "[search]"
cat "$SEARCH"
echo "take-remote-unseal-evidence: evidence in $OUT"

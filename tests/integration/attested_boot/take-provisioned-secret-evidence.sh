#!/usr/bin/env bash
#
# Take one machine's evidence about where a released secret lands, and
# what is left on its disk after it is power cycled.
#
# This is the third of the harnesses beside it. The first asks a guest
# what it measured; the second asks whether a secret its TPM holds can
# still be recovered after a power cycle. This one releases a secret to
# a running machine over a network socket, and then asks the **block
# device** whether the secret is on it.
#
# One run is ONE MACHINE across TWO POWER CYCLES. A single raw disk
# image is attached as a virtio block device and persists across both;
# nothing else does.
#
#   cycle           what the guest is asked to do
#   --------------  ---------------------------------------------------
#   provision       bring up the attestation agent, let the host verify
#                   a key agreement and hand back an HPKE-wrapped
#                   secret, decrypt it into the runtime directory, then
#                   write bulk data AND A PLANTED TOKEN to the disk and
#                   power off
#   after-reboot    boot again, report that the runtime directory is
#                   empty, confirm the disk still carries what the first
#                   cycle wrote, and power off
#
# THE ASSERTION IS A SEARCH OF THE DISK IMAGE, NOT A READING OF THE
# GUEST'S OWN ACCOUNT OF ITSELF. After the second cycle the host greps
# the raw image for two tokens:
#
#   * the SECRET, which must be ABSENT;
#   * the PLANTED TOKEN, which must be PRESENT.
#
# The second is not decoration. "The secret was not found" is worth
# nothing from a search that cannot find anything, and the planted token
# is written by the same guest, to the same filesystem, in the same
# cycle, and is recovered by the same search of the same image. It is
# the positive control that makes the negative result a measurement.
#
# THE SECOND POSITIVE CONTROL IS A REAL BOOT. With PROVISION_LEAK=1 the
# guest copies the released secret onto the persistent disk -- which is
# precisely the failure this whole gate exists to detect -- and the same
# search then FINDS it. Never use that flag for a capture meant to
# represent correct behaviour.
#
# Both tokens are printable: 64 hexadecimal characters drawn from the
# host's random source. That is a realistic shape for a released
# credential (an API key is one), and it makes the search auditable --
# anyone can re-run the grep by hand against the committed procedure.
#
#   take-provisioned-secret-evidence.sh <workdir>
#
# Environment (each is named out loud when missing; this harness never
# skips, because a run that quietly did nothing is worse than one that
# failed):
#
#   PROVISION_KERNEL    the kernel to boot.
#   PROVISION_KMOD      its module tree.
#   PROVISION_BUSYBOX   a STATIC shell and core utilities.
#   PROVISION_AGENT     the attestation-agent binary. Dynamically linked
#                       is fine and is the point: /nix/store is mounted
#                       in the guest before it runs, so the binary under
#                       test is the one this repository builds rather
#                       than a special static one.
#   PROVISION_RELEASER  the verifier-side releaser binary.
#   PROVISION_MKFS      mkfs.ext4, run on the HOST to format the image.
#
# Optional:
#
#   PROVISION_LEAK=1
#       Have the guest copy the released secret onto the persistent
#       disk. THE FAILURE MODE THIS GATE EXISTS TO DETECT, in evidence
#       form. Only the `provision` cycle is run under it.
#
#   PROVISION_PORT=<n>
#       The host port the guest's agent is forwarded to. Defaults to an
#       unused high port.
#
# WHAT THIS HARNESS DELIBERATELY DOES NOT DO, stated here rather than
# left for a reader to discover:
#
#   * There is NO unified kernel image, NO firmware, NO TPM and NO
#     measured boot. The guest boots straight into an initramfs and its
#     root of trust is a software one. Binding a release to real
#     hardware evidence is a different question, asked by a different
#     gate; this one asks where the plaintext went.
#   * The disk carries an ext4 filesystem with ordinary files. It is not
#     encrypted, which is the conservative choice: an encrypted volume
#     would make "the secret is not on the disk" true for a reason that
#     has nothing to do with the property under test.
#
# Everything the run creates is torn down unconditionally, including on
# the failure paths. The evidence directory is left, because it is the
# output.
set -euo pipefail

WORK="${1:?workdir}"

need() {
  local name=$1 value=${2:-}
  if [ -z "$value" ]; then
    echo "take-provisioned-secret-evidence: $name is not set. This" >&2
    echo "  harness boots a real machine and searches a real block" >&2
    echo "  device; it names what it could not find rather than" >&2
    echo "  reporting a skip, because a run that quietly did nothing" >&2
    echo "  is worse than one that failed." >&2
    exit 69
  fi
  printf '%s' "$value"
}

KERNEL=$(need PROVISION_KERNEL "${PROVISION_KERNEL:-}")
KMOD=$(need PROVISION_KMOD "${PROVISION_KMOD:-}")
BUSYBOX=$(need PROVISION_BUSYBOX "${PROVISION_BUSYBOX:-}")
AGENT=$(need PROVISION_AGENT "${PROVISION_AGENT:-}")
RELEASER=$(need PROVISION_RELEASER "${PROVISION_RELEASER:-}")
MKFS=$(need PROVISION_MKFS "${PROVISION_MKFS:-}")
LEAK="${PROVISION_LEAK:-0}"
PORT="${PROVISION_PORT:-$((20000 + RANDOM % 20000))}"

if ldd "$BUSYBOX" >/dev/null 2>&1; then
  echo "take-provisioned-secret-evidence: PROVISION_BUSYBOX must be" >&2
  echo "  statically linked; $BUSYBOX is not. Nothing is mounted when" >&2
  echo "  init starts, so a dynamic shell cannot find its interpreter." >&2
  exit 69
fi

SECRET_NAME="released-credential"
DISK_MIB=96

mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
OUT="$WORK/out"
IR="$WORK/initramfs"
rm -rf "$OUT" "$IR"
mkdir -p "$OUT" "$IR"/{bin,modules,proc,sys,dev,run,tmp,state,out,nix/store}

QEMU_PID=""
cleanup() {
  if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill -9 "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------
# The two tokens
#
# Drawn here, on the host, from the host's random source. The SECRET is
# never written anywhere the guest can read it except as ciphertext; the
# PLANTED token is handed to the guest in the clear on purpose.
# ---------------------------------------------------------------------
SECRET=$(head -c 32 /dev/urandom | od -v -An -tx1 | tr -d ' \n')
NEEDLE=$(head -c 32 /dev/urandom | od -v -An -tx1 | tr -d ' \n')
printf '%s' "$SECRET" > "$WORK/secret.txt"
chmod 600 "$WORK/secret.txt"
printf '%s' "$NEEDLE" > "$OUT/needle"
printf '%s' "$SECRET_NAME" > "$OUT/secret-name"
printf '%s' "$LEAK" > "$OUT/leak"

cat > "$WORK/policy.toml" <<'POLICY'
schema = "reproos.attestation-policy.v1"

# The guest has no hardware root of trust, so this policy admits the
# tier that has none and says so twice, which is the only way the parser
# lets it be said. The releaser declares the matching opt-in, so what
# this release rests on is written down in two places rather than
# assumed in either.
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
# The persistent disk
# ---------------------------------------------------------------------
rm -f "$WORK/state.img"
truncate -s "${DISK_MIB}M" "$WORK/state.img"
"$MKFS" -q -F -L provisionstate "$WORK/state.img" >/dev/null

# The image is searched at the end, so it is searched NOW as well, empty
# and freshly formatted. A token that were already present in a blank
# image would make every later result meaningless.
for label in secret needle; do
  case "$label" in
    secret) token=$SECRET ;;
    needle) token=$NEEDLE ;;
  esac
  if grep -c -a -F -- "$token" "$WORK/state.img" >/dev/null 2>&1; then
    echo "take-provisioned-secret-evidence: the $label token is already" >&2
    echo "  present in a freshly formatted image. Refusing to run: the" >&2
    echo "  search at the end would prove nothing." >&2
    exit 70
  fi
done

# ---------------------------------------------------------------------
# The initramfs
# ---------------------------------------------------------------------
cp "$BUSYBOX" "$IR/bin/busybox"
chmod +x "$IR/bin/busybox"
for ap in sh mount umount cp cat echo ls mkdir rm insmod sync poweroff sleep \
          dd printf od tr sed grep head cut wc env chmod ln true false \
          sha256sum awk ifconfig ip route stat date kill; do
  ln -sf busybox "$IR/bin/$ap"
done
cp "$AGENT" "$IR/bin/attestation-agent"
chmod +x "$IR/bin/attestation-agent"

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
         virtio_net net_failover failover rng-core virtio-rng \
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
mkdir -p /run/lock /tmp

while read -r m; do
  [ -n "$m" ] && insmod /modules/$m.ko 2>/dev/null
done < /modules/load.order

mount -t 9p -o trans=virtio,version=9p2000.L,ro nixstore /nix/store \
  || echo "PROVISION-FAIL: nixstore"
mount -t 9p -o trans=virtio,version=9p2000.L,rw outshare /out \
  || echo "PROVISION-FAIL: outshare"

echo "PROVISION-BEGIN"

CYCLE=$(cat /out/cycle 2>/dev/null)
LEAK=$(cat /out/leak 2>/dev/null)
NAME=$(cat /out/secret-name 2>/dev/null)
NEEDLE=$(cat /out/needle 2>/dev/null)
SECRETS_DIR=/run/attested-secrets
R=/out/report-$CYCLE.txt
: > $R
say() { echo "$*" >> $R; }

say "cycle=$CYCLE"
say "leak_requested=$LEAK"

ifconfig lo 127.0.0.1 netmask 255.0.0.0 up 2>/dev/null
ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up 2>/dev/null
route add default gw 10.0.2.2 2>/dev/null
say "eth0_up=$(ifconfig eth0 2>/dev/null | grep -c 'inet addr:10.0.2.15')"

mount -t ext4 /dev/vda /state
say "state_mount_rc=$?"
say "state_fstype=$(awk '$2=="/state"{print $3}' /proc/mounts)"
say "run_fstype=$(awk '$2=="/run"{print $3}' /proc/mounts)"

if [ "$CYCLE" = "provision" ]; then
  # The runtime directory is the agent's to create. It is inside /run,
  # which is the tmpfs mounted above, and the agent refuses to release
  # into anything that is not one.
  attestation-agent serve --listen=0.0.0.0:7331 \
      --generation=provision-harness-gen-1 \
      --config-fingerprint=reproos-provision-harness \
      --verity-root-hash=0000000000000000000000000000000000000000000000000000000000000000 \
      --provisioned-secrets-dir=$SECRETS_DIR > /out/agent.log 2>&1 &
  AGENT_PID=$!
  say "agent_pid=$AGENT_PID"

  i=0
  while [ ! -s "$SECRETS_DIR/$NAME" ] && [ $i -lt 180 ]; do
    sleep 1
    i=$((i + 1))
  done
  say "waited_seconds=$i"

  if [ -s "$SECRETS_DIR/$NAME" ]; then
    say "secret_present=1"
    say "secret_bytes=$(wc -c < $SECRETS_DIR/$NAME)"
    say "secret_sha256=$(sha256sum < $SECRETS_DIR/$NAME | cut -d' ' -f1)"
    say "secret_mode=$(ls -l $SECRETS_DIR/$NAME | cut -c1-10)"
    say "secrets_dir_fstype=$(awk '$2=="/run"{print $3}' /proc/mounts)"
  else
    say "secret_present=0"
    say "secret_bytes=0"
    say "secret_sha256=-"
    say "secret_mode=-"
    say "secrets_dir_fstype=-"
  fi

  # Bulk writes, so the image the host searches is a used filesystem
  # rather than a blank one, and the planted token, which is what makes
  # the search's negative result mean anything.
  mkdir -p /state/data
  i=0
  while [ $i -lt 24 ]; do
    dd if=/dev/urandom of=/state/data/blob-$i bs=64k count=4 2>/dev/null
    i=$((i + 1))
  done
  printf '%s' "$NEEDLE" > /state/planted.txt
  say "planted_bytes=$(wc -c < /state/planted.txt)"

  if [ "$LEAK" = "1" ] && [ -s "$SECRETS_DIR/$NAME" ]; then
    # THE FAILURE MODE, on purpose. See the header.
    cp "$SECRETS_DIR/$NAME" /state/leaked-secret.txt
    say "leaked_to_disk=1"
  else
    say "leaked_to_disk=0"
  fi
  say "state_files=$(ls /state/data | wc -l)"
  kill $AGENT_PID 2>/dev/null
else
  say "secrets_dir_present=$([ -d $SECRETS_DIR ] && echo 1 || echo 0)"
  say "secrets_dir_entries=$(ls -A $SECRETS_DIR 2>/dev/null | wc -l)"
  say "planted_on_disk=$([ -f /state/planted.txt ] && echo 1 || echo 0)"
  if [ -f /state/planted.txt ]; then
    say "planted_matches=$([ "$(cat /state/planted.txt)" = "$NEEDLE" ] \
        && echo 1 || echo 0)"
  else
    say "planted_matches=0"
  fi
  say "state_files=$(ls /state/data 2>/dev/null | wc -l)"
  say "leaked_on_disk=$([ -f /state/leaked-secret.txt ] && echo 1 || echo 0)"
fi

sync
umount /state
say "done=1"
sync
echo "PROVISION-END"
poweroff -f
INIT
chmod +x "$IR/init"

( cd "$IR" && find . -print0 | sort -z | cpio --null -o -H newc --quiet \
  | gzip -9 > "$WORK/initrd.img" )

# ---------------------------------------------------------------------
# One power cycle
# ---------------------------------------------------------------------
run_cycle() {
  local cycle=$1 with_releaser=$2
  printf '%s' "$cycle" > "$OUT/cycle"
  rm -f "$OUT/report-$cycle.txt"
  echo "[cycle] $cycle"

  qemu-system-x86_64 \
    -enable-kvm -m 1024 -smp 2 -display none -no-reboot \
    -kernel "$KERNEL" -initrd "$WORK/initrd.img" \
    -append "console=ttyS0 panic=5 rdinit=/init" \
    -serial "file:$WORK/console-$cycle.log" \
    -drive "file=$WORK/state.img,format=raw,if=virtio,cache=writeback" \
    -fsdev local,id=nixstore,path=/nix/store,security_model=none,readonly=on \
    -device virtio-9p-pci,fsdev=nixstore,mount_tag=nixstore \
    -fsdev "local,id=outshare,path=$OUT,security_model=none" \
    -device virtio-9p-pci,fsdev=outshare,mount_tag=outshare \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-10.0.2.15:7331" \
    -device virtio-net-pci,netdev=n0 \
    >"$WORK/qemu-$cycle.log" 2>&1 &
  QEMU_PID=$!

  if [ "$with_releaser" = "1" ]; then
    # The verifier, on the host, over the network. It polls /health, so
    # it is started immediately and waits for the machine on its own.
    set +e
    "$RELEASER" --agent="http://127.0.0.1:$PORT" --out="$OUT" \
      --secret-file="$WORK/secret.txt" --name="$SECRET_NAME" \
      --policy="$WORK/policy.toml" --timeout-seconds=180 \
      >"$WORK/releaser.log" 2>&1
    local rc=$?
    set -e
    echo "[releaser] exit $rc"
  fi

  local waited=0
  while kill -0 "$QEMU_PID" 2>/dev/null && [ $waited -lt 300 ]; do
    sleep 2
    waited=$((waited + 2))
  done
  if kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "take-provisioned-secret-evidence: the $cycle guest did not" >&2
    echo "  power off within ${waited}s." >&2
    kill -9 "$QEMU_PID" 2>/dev/null || true
  fi
  wait "$QEMU_PID" 2>/dev/null || true
  QEMU_PID=""

  if [ ! -s "$OUT/report-$cycle.txt" ]; then
    echo "take-provisioned-secret-evidence: the $cycle guest wrote no" >&2
    echo "  report. See $WORK/console-$cycle.log." >&2
    exit 71
  fi
}

run_cycle provision 1
if [ "$LEAK" != "1" ]; then
  run_cycle after-reboot 0
fi

# ---------------------------------------------------------------------
# The search
#
# Of the raw image file, by the host, with no guest involved. This is
# the assertion the whole harness exists to produce, and it is
# deliberately the simplest thing that can be checked by hand: a
# fixed-string grep for a printable token over the whole device.
# ---------------------------------------------------------------------
search() {   # $1 = token
  grep -c -a -F -- "$1" "$WORK/state.img" 2>/dev/null || true
}

SEARCH="$OUT/disk-search.txt"
{
  echo "image=$(basename "$WORK/state.img")"
  echo "image_bytes=$(wc -c < "$WORK/state.img")"
  echo "token_chars=${#SECRET}"
  echo "secret_sha256=$(printf '%s' "$SECRET" | sha256sum | cut -d' ' -f1)"
  echo "planted_sha256=$(printf '%s' "$NEEDLE" | sha256sum | cut -d' ' -f1)"
  echo "secret_hits=$(search "$SECRET")"
  echo "planted_hits=$(search "$NEEDLE")"
  echo "leak_requested=$LEAK"
} > "$SEARCH"

# The searcher is shown to be able to find THIS token in THIS image.
# Without this line, "secret_hits=0" is equally consistent with a
# perfectly clean machine and with a grep that never matches anything.
cp "$WORK/state.img" "$WORK/state-with-secret.img"
printf '%s' "$SECRET" >> "$WORK/state-with-secret.img"
echo "secret_hits_when_planted=$(grep -c -a -F -- "$SECRET" \
  "$WORK/state-with-secret.img" 2>/dev/null || true)" >> "$SEARCH"
rm -f "$WORK/state-with-secret.img"

echo "[search]"
cat "$SEARCH"
echo "take-provisioned-secret-evidence: evidence in $OUT"

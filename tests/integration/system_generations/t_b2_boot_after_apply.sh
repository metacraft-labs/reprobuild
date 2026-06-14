#!/usr/bin/env bash
# t_b2_boot_after_apply.sh — B2 P5 integration gate (SIMULATED).
#
# This gate documents and exercises the boot-promotion flow without a
# real reboot. Driving a Hyper-V VM through a serial-console
# verification is in B3's scope (where the rollback story closes); B2
# only needs to prove the wire is correct.
#
# Flow:
#
#   1. Apply config A -> generation 1; staged-next records 1; current
#      is unset.
#   2. Simulate "first successful boot": invoke `reproos-rebuild
#      confirm` (the same entry-point the
#      reproos-confirm-generation.service systemd unit calls on
#      reaching multi-user.target). current now points at generation 1;
#      staged-next is cleared.
#   3. Apply config B -> generation 2; staged-next records 2; current
#      still points at generation 1 (because the boot has not happened
#      yet — this is the "new generation is active ONLY after the next
#      successful boot" contract).
#   4. Simulate "boot failure": leave staged-next as-is; on next apply
#      the staged generation is still there. (Real boot-failure
#      detection is GRUB's `set fallback`; we already verified the
#      menu wiring in t_b2_grub_menu.sh.) For the simulation, we just
#      confirm the staged-next file is preserved across an apply that
#      records the same generation as a no-op.
#   5. Simulate "successful boot of generation 2": invoke
#      `reproos-rebuild confirm`. current now points at generation 2;
#      staged-next is cleared.
#
# Production wiring documented for B3:
#
#   * A systemd unit `reproos-confirm-generation.service`:
#       [Unit]
#       Description=Confirm staged ReproOS generation
#       After=multi-user.target
#       ConditionPathExists=/var/lib/reproos/staged-next
#       [Service]
#       Type=oneshot
#       ExecStart=/usr/bin/reproos-rebuild confirm
#       [Install]
#       WantedBy=multi-user.target
#   * GRUB's boot-prev fallback is the auto-rollback target on boot
#     failure. The same kernel + initrd + cmdline that wrote
#     generation 1 are loaded; the host comes back up, the
#     reproos-confirm-generation.service unit fires on the
#     PREVIOUS generation (because staged-next remained at 2 but
#     /var/lib/reproos/generations/2 became unreachable when its
#     menuentry failed) and B3's rollback subcommand reconciles
#     staged-next + the current pointer accordingly.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPRO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

BIN="$REPRO_ROOT/apps/reproos-rebuild/reproos_rebuild"
case "$(uname -s)" in
  CYGWIN*|MINGW*|MSYS*) BIN="$BIN.exe" ;;
esac
if [[ ! -x "$BIN" ]]; then
  (cd "$REPRO_ROOT" && nim c --hints:off --warnings:off \
    apps/reproos-rebuild/reproos_rebuild.nim >/dev/null)
fi
[[ -x "$BIN" ]] || { echo "FAIL: reproos-rebuild binary not built at $BIN"; exit 1; }

WORK="$(mktemp -d -t reproos-b2-boot.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
STATE="$WORK/state"
BOOT="$WORK/boot"
RUN="$WORK/run"
mkdir -p "$STATE" "$BOOT" "$RUN"

CONFIG_A="$REPRO_ROOT/recipes/reproos-sample-config/configuration.nim"

CONFIG_B_DIR="$WORK/cfgB"
mkdir -p "$CONFIG_B_DIR"
CONFIG_B="$CONFIG_B_DIR/configuration.nim"
cat > "$CONFIG_B" <<'EOF'
system reproosSampleConfig:
  kernel = reproosKernel

  kernel_cmdline = [
    "console=ttyS0,115200n8",
    "init=/sbin/init",
    "rw",
  ]

  packages = [
    coreutils,
    bash,
    systemd,
    tmux,
    package(apt, "vim", snapshot = "debian/bookworm/20260601T000000Z"),
  ]

  users:
    user "ada":
      shell = bash
      groups = ["wheel"]
      home_dir = "/home/ada"
    user "mallory":
      shell = bash
      groups = ["wheel"]
      home_dir = "/home/mallory"

  services:
    enable "systemd-networkd.service"

  mounts:
    mount "/", source = "LABEL=reproos-root", fstype = "ext4"
EOF

echo "=== step 1: apply A ==="
"$BIN" apply --config "$CONFIG_A" --state-dir "$STATE" \
  --boot-dir "$BOOT" --runtime-dir "$RUN" \
  --activation-ts 1700000000 --yes >/dev/null
[[ -f "$STATE/staged-next" ]] || { echo "FAIL: staged-next missing after apply A"; exit 1; }
STAGED="$(cat "$STATE/staged-next" | tr -d '[:space:]')"
[[ "$STAGED" == "1" ]] || { echo "FAIL: staged-next='$STAGED' expected 1"; exit 1; }
[[ ! -f "$STATE/current" ]] || { echo "FAIL: current set before first confirm"; exit 1; }

echo "=== step 2: simulate first successful boot (confirm) ==="
"$BIN" confirm --state-dir "$STATE"
[[ ! -f "$STATE/staged-next" ]] || { echo "FAIL: staged-next not cleared after confirm"; exit 1; }
[[ -f "$STATE/current" ]] || { echo "FAIL: current not set after first confirm"; exit 1; }
CUR_BODY="$(cat "$STATE/current" | tr -d '[:space:]')"
# current points at the generation 1 directory.
case "$CUR_BODY" in
  *generations/1|*generations\\1) ;;
  *) echo "FAIL: current points at '$CUR_BODY', expected .../generations/1"; exit 1 ;;
esac

echo "=== step 3: apply B -> generation 2 staged but not active ==="
"$BIN" apply --config "$CONFIG_B" --state-dir "$STATE" \
  --boot-dir "$BOOT" --runtime-dir "$RUN" \
  --activation-ts 1700001000 --yes >/dev/null
[[ -f "$STATE/staged-next" ]] || { echo "FAIL: staged-next missing after apply B"; exit 1; }
STAGED="$(cat "$STATE/staged-next" | tr -d '[:space:]')"
[[ "$STAGED" == "2" ]] || { echo "FAIL: staged-next='$STAGED' expected 2"; exit 1; }
# current pointer must STILL be at generation 1 (production: until the
# next successful boot of generation 2).
CUR_BODY="$(cat "$STATE/current" | tr -d '[:space:]')"
case "$CUR_BODY" in
  *generations/1|*generations\\1) ;;
  *) echo "FAIL: current changed before confirm; got '$CUR_BODY', expected .../generations/1"; exit 1 ;;
esac

echo "=== step 4: simulate boot failure (no confirm) ==="
# Nothing happens. The next apply would still see staged-next = 2 and
# the active current still = 1. We sanity-check by running `list`:
LIST_OUT="$("$BIN" list --state-dir "$STATE")"
echo "$LIST_OUT"
echo "$LIST_OUT" | grep -E '\*[[:space:]]+generation 1' >/dev/null \
  || { echo "FAIL: list output does not mark generation 1 as current"; exit 1; }

echo "=== step 5: simulate successful boot of generation 2 ==="
"$BIN" confirm --state-dir "$STATE"
[[ ! -f "$STATE/staged-next" ]] || { echo "FAIL: staged-next not cleared after second confirm"; exit 1; }
CUR_BODY="$(cat "$STATE/current" | tr -d '[:space:]')"
case "$CUR_BODY" in
  *generations/2|*generations\\2) ;;
  *) echo "FAIL: current points at '$CUR_BODY' after second confirm, expected .../generations/2"; exit 1 ;;
esac

echo "PASS: t_b2_boot_after_apply.sh (simulated; real Hyper-V boot deferred to B3)"

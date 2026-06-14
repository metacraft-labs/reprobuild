#!/usr/bin/env bash
# Shared helpers for the B3 integration tests.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/_b3_common.sh"
#
# Exports:
#   REPRO_ROOT
#   BIN
#   CONFIG_A          -- the sample config (the "from-source" baseline)
#   make_workspace LABEL  -> echoes a fresh temp dir; sets STATE / BOOT / RUN
#   apply_config FILE TS  -- run `reproos-rebuild apply --yes`
#   confirm_state         -- run `reproos-rebuild confirm`

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

CONFIG_A="$REPRO_ROOT/recipes/reproos-sample-config/configuration.nim"
[[ -f "$CONFIG_A" ]] || { echo "FAIL: sample config not at $CONFIG_A"; exit 1; }

make_workspace() {
  # Sets WORK / STATE / BOOT / RUN in the caller's shell. Do NOT
  # invoke via command substitution — the subshell would discard the
  # variable assignments.
  local label="$1"
  WORK="$(mktemp -d -t "reproos-${label}.XXXXXX")"
  STATE="$WORK/state"
  BOOT="$WORK/boot"
  RUN="$WORK/run"
  mkdir -p "$STATE" "$BOOT" "$RUN"
}

apply_config() {
  local cfg="$1"
  local ts="$2"
  "$BIN" apply \
    --config "$cfg" \
    --state-dir "$STATE" \
    --boot-dir "$BOOT" \
    --runtime-dir "$RUN" \
    --activation-ts "$ts" \
    --yes
}

confirm_state() {
  "$BIN" confirm --state-dir "$STATE"
}

# Service-only config B: same kernel + cmdline as A but enables
# systemd-resolved.
write_config_service_only() {
  local out="$1"
  cat > "$out" <<'EOF'
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
    package(apt, "vim", snapshot = "debian/bookworm/20260601T000000Z"),
  ]

  users:
    user "root":
      shell = bash
      password_hash = "$y$j9T$rootpw"
    user "ada":
      shell = bash
      groups = ["wheel", "video", "audio"]
      home_dir = "/home/ada"

  services:
    enable "systemd-networkd.service"
    enable "serial-getty@ttyS0.service"
    enable "systemd-resolved.service"

  mounts:
    mount "/", source = "LABEL=reproos-root", fstype = "ext4", options = "ro,relatime"
    mount "/boot", source = "LABEL=reproos-boot", fstype = "vfat", options = "umask=0077"
EOF
}

# Kernel-changing config C: different kernel + a quieter cmdline.
write_config_kernel_change() {
  local out="$1"
  cat > "$out" <<'EOF'
system reproosSampleConfig:
  kernel = reproosKernelHardened

  kernel_cmdline = [
    "console=ttyS0,115200n8",
    "init=/sbin/init",
    "rw",
    "audit=1",
  ]

  packages = [
    coreutils,
    bash,
    systemd,
    package(apt, "vim", snapshot = "debian/bookworm/20260601T000000Z"),
  ]

  users:
    user "root":
      shell = bash
      password_hash = "$y$j9T$rootpw"
    user "ada":
      shell = bash
      groups = ["wheel", "video", "audio"]
      home_dir = "/home/ada"

  services:
    enable "systemd-networkd.service"
    enable "serial-getty@ttyS0.service"
    disable "systemd-resolved.service"

  mounts:
    mount "/", source = "LABEL=reproos-root", fstype = "ext4", options = "ro,relatime"
    mount "/boot", source = "LABEL=reproos-boot", fstype = "vfat", options = "umask=0077"
EOF
}

#!/usr/bin/env bash
# t_b2_grub_menu.sh — B2 P5 integration gate.
#
# After two consecutive applies, asserts that:
#   * the GRUB menu the CLI emits has two menuentry blocks for the
#     recorded generations (newest-first) AND a third boot-prev block.
#   * the active (= staged-next) generation 2 is the GRUB default.
#   * the boot-prev entry references generation 1's kernel placeholder.
#   * the on-disk grub.cfg written by `reproos-rebuild apply` matches
#     the standalone `reproos-rebuild grub` output (a sanity check
#     that the two emission paths agree on the byte layout).

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

WORK="$(mktemp -d -t reproos-b2-grub.XXXXXX)"
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

"$BIN" apply --config "$CONFIG_A" --state-dir "$STATE" \
  --boot-dir "$BOOT" --runtime-dir "$RUN" \
  --activation-ts 1700000000 --yes >/dev/null

"$BIN" apply --config "$CONFIG_B" --state-dir "$STATE" \
  --boot-dir "$BOOT" --runtime-dir "$RUN" \
  --activation-ts 1700001000 --yes >/dev/null

# Compare the on-disk grub.cfg with the standalone `grub` subcommand.
ONDISK_GRUB="$BOOT/grub/grub.cfg"
[[ -f "$ONDISK_GRUB" ]] || { echo "FAIL: $ONDISK_GRUB missing"; exit 1; }
STANDALONE_GRUB="$WORK/standalone-grub.cfg"
"$BIN" grub --state-dir "$STATE" > "$STANDALONE_GRUB"

# The two emission paths must agree.
if ! diff -q "$ONDISK_GRUB" "$STANDALONE_GRUB" >/dev/null; then
  echo "FAIL: on-disk grub.cfg differs from standalone emit"
  diff "$ONDISK_GRUB" "$STANDALONE_GRUB" || true
  exit 1
fi

# Two per-gen menuentries + one boot-prev menuentry.
ENTRY_COUNT=$(grep -c '^menuentry' "$ONDISK_GRUB")
[[ "$ENTRY_COUNT" == "3" ]] || { echo "FAIL: expected 3 menuentries, found $ENTRY_COUNT"; exit 1; }

# Generation 2 is default.
grep -q 'set default="reproos-gen-2"' "$ONDISK_GRUB" || { echo "FAIL: default not gen 2"; exit 1; }
# fallback wired to boot-prev.
grep -q 'set fallback="reproos-boot-prev"' "$ONDISK_GRUB" || { echo "FAIL: fallback not boot-prev"; exit 1; }
# Newest-first: gen-2 menuentry precedes gen-1 menuentry.
GEN2_LINE=$(grep -n "reproos-gen-2'" "$ONDISK_GRUB" | head -1 | cut -d: -f1)
GEN1_LINE=$(grep -n "reproos-gen-1'" "$ONDISK_GRUB" | head -1 | cut -d: -f1)
[[ "$GEN2_LINE" -lt "$GEN1_LINE" ]] || { echo "FAIL: newest-first ordering violated"; exit 1; }
# Boot-prev menuentry comes AFTER both per-gen entries.
BP_LINE=$(grep -n "reproos-boot-prev'" "$ONDISK_GRUB" | head -1 | cut -d: -f1)
[[ "$BP_LINE" -gt "$GEN1_LINE" ]] || { echo "FAIL: boot-prev not at end of menu"; exit 1; }
# Boot-prev references generation 1's kernel placeholder.
sed -n "${BP_LINE},/^}/p" "$ONDISK_GRUB" \
  | grep -qE '(generations/1/boot/vmlinuz|generations\\1\\boot\\vmlinuz)' \
  || { echo "FAIL: boot-prev entry does not reference generation 1's kernel"; exit 1; }

echo "PASS: t_b2_grub_menu.sh"

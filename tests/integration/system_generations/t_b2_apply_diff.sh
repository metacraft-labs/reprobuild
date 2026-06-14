#!/usr/bin/env bash
# t_b2_apply_diff.sh — B2 P5 integration gate.
#
# Exercises the diff pass + the "existing state preserved" property:
#
#   1. Apply config A (the sample config) -> generation 1.
#   2. Apply config B (sample config + one extra Tier-1 package +
#      one extra user) -> generation 2.
#   3. Walk generation 2's manifest and confirm that:
#        - the extra package's placeholder exists in generation 2
#        - the extra user's `/etc/passwd` entry exists in generation 2
#        - the user/package set from generation 1 also exists in 2
#          (existing state preserved across the transition)
#        - generation 1's directory is INTACT (no in-place mutation)

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

WORK="$(mktemp -d -t reproos-b2-diff.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
STATE="$WORK/state"
BOOT="$WORK/boot"
RUN="$WORK/run"
mkdir -p "$STATE" "$BOOT" "$RUN"

CONFIG_A="$REPRO_ROOT/recipes/reproos-sample-config/configuration.nim"
[[ -f "$CONFIG_A" ]] || { echo "FAIL: sample config not at $CONFIG_A"; exit 1; }

# Stage config B: a duplicate of A with an extra package + user.
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
    user "root":
      shell = bash
      password_hash = "$y$j9T$rootpw"
    user "ada":
      shell = bash
      groups = ["wheel", "video", "audio"]
      home_dir = "/home/ada"
    user "mallory":
      shell = bash
      groups = ["wheel"]
      home_dir = "/home/mallory"

  services:
    enable "systemd-networkd.service"
    enable "serial-getty@ttyS0.service"
    disable "systemd-resolved.service"

  mounts:
    mount "/", source = "LABEL=reproos-root", fstype = "ext4", options = "ro,relatime"
    mount "/boot", source = "LABEL=reproos-boot", fstype = "vfat", options = "umask=0077"
EOF

echo "=== apply config A ==="
"$BIN" apply \
  --config "$CONFIG_A" \
  --state-dir "$STATE" \
  --boot-dir "$BOOT" \
  --runtime-dir "$RUN" \
  --activation-ts 1700000000 \
  --yes

GEN1_DIR="$STATE/generations/1"
[[ -d "$GEN1_DIR" ]] || { echo "FAIL: generation 1 directory missing"; exit 1; }

# Snapshot generation 1's manifest bytes for the post-apply-B
# "intact" check.
GEN1_MANIFEST_BEFORE="$(cat "$GEN1_DIR/manifest.txt")"
GEN1_PASSWD_BEFORE="$(cat "$GEN1_DIR/etc/passwd")"

echo "=== plan config B (sanity) ==="
DIFF_OUT="$("$BIN" plan \
  --config "$CONFIG_B" \
  --state-dir "$STATE" \
  --boot-dir "$BOOT" \
  --runtime-dir "$RUN")"
echo "$DIFF_OUT"
# The diff should record at least the tmux addition and the mallory
# addition.
echo "$DIFF_OUT" | grep -q '+ package tmux' || { echo "FAIL: diff missing '+ package tmux'"; exit 1; }
echo "$DIFF_OUT" | grep -q '+ user mallory' || { echo "FAIL: diff missing '+ user mallory'"; exit 1; }
# The diff should NOT record a mount or kernel-cmdline change.
if echo "$DIFF_OUT" | grep -qE '(^|\n)[+~-] mount'; then
  echo "FAIL: diff carries an unexpected mount transition"; exit 1
fi
if echo "$DIFF_OUT" | grep -qE '(^|\n)[+~-] kernel-cmdline'; then
  echo "FAIL: diff carries an unexpected kernel-cmdline transition"; exit 1
fi

echo "=== apply config B ==="
"$BIN" apply \
  --config "$CONFIG_B" \
  --state-dir "$STATE" \
  --boot-dir "$BOOT" \
  --runtime-dir "$RUN" \
  --activation-ts 1700001000 \
  --yes

GEN2_DIR="$STATE/generations/2"
[[ -d "$GEN2_DIR" ]] || { echo "FAIL: generation 2 directory missing"; exit 1; }

# Existing state preserved: every package + user from A is still in B.
for p in coreutils bash systemd vim; do
  [[ -f "$GEN2_DIR/packages/$p" ]] || { echo "FAIL: package $p missing from generation 2"; exit 1; }
done
# New package + user are present.
[[ -f "$GEN2_DIR/packages/tmux" ]] || { echo "FAIL: tmux placeholder missing"; exit 1; }
grep -q '^mallory:' "$GEN2_DIR/etc/passwd" || { echo "FAIL: mallory missing from /etc/passwd"; exit 1; }
grep -q '^ada:' "$GEN2_DIR/etc/passwd" || { echo "FAIL: ada missing from generation 2 /etc/passwd"; exit 1; }
grep -q '^root:' "$GEN2_DIR/etc/passwd" || { echo "FAIL: root missing from generation 2 /etc/passwd"; exit 1; }

# Generation 1 directory is intact.
GEN1_MANIFEST_AFTER="$(cat "$GEN1_DIR/manifest.txt")"
GEN1_PASSWD_AFTER="$(cat "$GEN1_DIR/etc/passwd")"
[[ "$GEN1_MANIFEST_BEFORE" == "$GEN1_MANIFEST_AFTER" ]] || { echo "FAIL: generation 1 manifest mutated"; exit 1; }
[[ "$GEN1_PASSWD_BEFORE" == "$GEN1_PASSWD_AFTER" ]] || { echo "FAIL: generation 1 /etc/passwd mutated"; exit 1; }

# staged-next records 2.
STAGED="$(cat "$STATE/staged-next" | tr -d '[:space:]')"
[[ "$STAGED" == "2" ]] || { echo "FAIL: staged-next records '$STAGED', expected 2"; exit 1; }

echo "PASS: t_b2_apply_diff.sh"

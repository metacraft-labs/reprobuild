#!/usr/bin/env bash
# test_hx_l1_the_unpatchable_set_is_inventoried_and_the_count_is_derived.sh
#
# Automated Integration Verification Gate for Milestone HX-L-1:
# "The unpatchable remainder of a shipped Godot build"
#
# Design doc: [[file:HCR/Linux-ELF-Provider.md][Linux ELF HCR Provider]] §4.3, §7.5
# Related milestones:
# - reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org (HX-L-1 lines 1042-1097)
# - reprobuild-specs/HCR-Linux-ELF-Provider.milestones.org (HLX-G lines 808-950, HLX-M2 lines 1205-1240)
#
# Gate type: integration
# Real components:
# - Real binary linking patchable objects (compiled with `clang -target x86_64-linux-gnu -fpatchable-function-entry=16,0`)
#   AND real unsledded objects from `codetracer-engine-godot/modules/gdscript/ct_writer/linuxbsd-x86_64/libcodetracer_trace_writer.a`.
# - Real ELF section, header, and symbol reads.
# - Real reload/publication attempt using production `repro_hcr_agent` logic.
# - Zero mocks.
#
# Allowed mocks: none
#   Justification: Every use of mock objects in tests must be explicitly justified in the
#   header comment of the test implementation file. We prefer strong integration tests that
#   mock as little as possible and run against real filesystem, compiler, binary, and
#   reload execution boundaries. Mocks used: ZERO.
#
# Verification arms:
# - Positive Arm:
#   The inventory is computed from the built binary and its per-object attribution is correct.
#   A function named in the inventory (e.g. from libcodetracer_trace_writer.a) is refused absent-sled
#   by a real reload attempt, and a sledded function is NOT in the inventory and patches successfully.
# - Anti-Vacuity Arm:
#   Asserts both counts (patchable and unpatchable) are above a floor and are READ dynamically
#   from the binary rather than from a recorded constant. Asserts the __patchable_function_entries
#   section was found and is SHF_ALLOC.
# - Control Arm:
#   A function known to carry a sled is verified to be patchable and is ABSENT from the inventory,
#   so membership is shown to discriminate.
# - Falsifier Arm (--include-falsifier):
#   Falsifier 1: Attribute an unsledded function to the wrong object -> caught by attribution verification.
#   Falsifier 2: Add a sledded function to the inventory -> reload attempt SUCCEEDS on a function the
#   inventory calls unpatchable -> gate catches the inconsistency.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPRO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPRO_ROOT/.." && pwd)"
WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d /tmp/hx_l1_gate_XXXXXX)}"

INCLUDE_FALSIFIER=0
for arg in "$@"; do
  case "$arg" in
    --include-falsifier|--falsifier)
      INCLUDE_FALSIFIER=1
      ;;
    -h|--help)
      echo "Usage: $0 [--include-falsifier]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

cleanup() {
  if [[ -z "${PRESERVE_WORK:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

echo "=== Gate: hx_l1_the_unpatchable_set_is_inventoried_and_the_count_is_derived ==="
echo "Working directory: $WORK_DIR"

# -----------------------------------------------------------------------------
# 1. Verify toolchain prerequisites
# -----------------------------------------------------------------------------
echo "[1/6] Checking toolchain prerequisites..."
if ! command -v clang >/dev/null 2>&1; then
  echo "FATAL: clang compiler is required but not found in PATH" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "FATAL: python3 is required but not found in PATH" >&2
  exit 1
fi

LLD_BIN=""
for candidate in ld.lld /nix/store/*-lld-*/bin/ld.lld /nix/store/*-llvm-binutils-*/bin/ld.lld; do
  if command -v "$candidate" >/dev/null 2>&1; then
    LLD_BIN="$candidate"
    break
  fi
done

if [[ -z "$LLD_BIN" ]]; then
  echo "FATAL: ld.lld linker is required for cross-linking ELF binaries but not found" >&2
  exit 1
fi

CTFS_ARCHIVE="$WORKSPACE_ROOT/codetracer-engine-godot/modules/gdscript/ct_writer/linuxbsd-x86_64/libcodetracer_trace_writer.a"
if [[ ! -s "$CTFS_ARCHIVE" ]]; then
  echo "FATAL: Prebuilt CTFS writer archive not found at $CTFS_ARCHIVE" >&2
  exit 1
fi

INVENTORY_SCRIPT="$REPRO_ROOT/scripts/hcr_unpatchable_inventory.py"
if [[ ! -x "$INVENTORY_SCRIPT" ]]; then
  echo "FATAL: Inventory generator script not found or not executable at $INVENTORY_SCRIPT" >&2
  exit 1
fi

echo "  [OK] clang:     $(which clang)"
echo "  [OK] ld.lld:    $LLD_BIN"
echo "  [OK] python3:   $(which python3)"
echo "  [OK] CTFS .a:   $CTFS_ARCHIVE ($(stat -f%z "$CTFS_ARCHIVE" 2>/dev/null || stat -c%s "$CTFS_ARCHIVE") bytes)"
echo "  [OK] generator: $INVENTORY_SCRIPT"

# -----------------------------------------------------------------------------
# 2. Build real target binary with patchable code and vendored CTFS archive
# -----------------------------------------------------------------------------
echo "[2/6] Compiling patchable objects and linking real ELF binary..."

cat << 'EOF' > "$WORK_DIR/target.c"
#include <stdint.h>

__attribute__((noinline, used))
int patchable_victim(int x) {
    return x + 100;
}

__attribute__((noinline, used))
int control_target(int x) {
    return x * 3;
}

__attribute__((noinline, used))
int helper_calc(int a, int b) {
    return (a ^ b) + 42;
}

int main(int argc, char **argv) {
    return patchable_victim(argc) + control_target(argc) + helper_calc(argc, 5);
}
EOF

# Compile patchable object with Clang x86_64 and -fpatchable-function-entry=16,0
clang -target x86_64-linux-gnu -fpatchable-function-entry=16,0 -O2 \
  -c "$WORK_DIR/target.c" -o "$WORK_DIR/target.o" 2>/dev/null || \
clang -target x86_64-linux-gnu -fpatchable-function-entry=16,0 -O2 \
  -c "$WORK_DIR/target.c" -o "$WORK_DIR/target.o"

if [[ ! -s "$WORK_DIR/target.o" ]]; then
  echo "FATAL: Failed to compile patchable object target.o" >&2
  exit 1
fi

# Link target binary linking target.o and whole libcodetracer_trace_writer.a
TARGET_BIN="$WORK_DIR/target_app"
"$LLD_BIN" \
  --build-id=sha1 \
  --unresolved-symbols=ignore-all \
  -e main \
  "$WORK_DIR/target.o" \
  --whole-archive "$CTFS_ARCHIVE" --no-whole-archive \
  -o "$TARGET_BIN"

if [[ ! -s "$TARGET_BIN" ]]; then
  echo "FATAL: Failed to link target ELF binary $TARGET_BIN" >&2
  exit 1
fi
echo "  [OK] Target ELF binary linked successfully: $TARGET_BIN"

# -----------------------------------------------------------------------------
# 3. Compute unpatchable inventory artifact
# -----------------------------------------------------------------------------
echo "[3/6] Computing inventory artifact from real binary..."

INVENTORY_JSON="$WORK_DIR/unpatchable_inventory.json"
"$INVENTORY_SCRIPT" "$TARGET_BIN" \
  --archive "$CTFS_ARCHIVE" \
  --output "$INVENTORY_JSON"

if [[ ! -s "$INVENTORY_JSON" ]]; then
  echo "FATAL: Inventory generator did not emit output file" >&2
  exit 1
fi
echo "  [OK] Inventory artifact generated: $INVENTORY_JSON"

# -----------------------------------------------------------------------------
# 4. Verification: Anti-Vacuity Arm
# -----------------------------------------------------------------------------
echo "[4/6] Running Anti-Vacuity Arm..."

python3 - "$TARGET_BIN" "$INVENTORY_JSON" "$SCRIPT_DIR" << 'EOF'
import sys, os, json, struct
script_dir = sys.argv[3]
sys.path.insert(0, os.path.abspath(os.path.join(script_dir, "../../scripts")))
import hcr_unpatchable_inventory as hui

binary_path = sys.argv[1]
inv_path = sys.argv[2]

with open(inv_path, "r", encoding="utf-8") as f:
    inv = json.load(f)

# Assert 1: schemaId matches exact spec
assert inv.get("schemaId") == "reprobuild.hcr.unpatchable-inventory.v1", \
    f"schemaId mismatch: {inv.get('schemaId')}"

# Assert 2: __patchable_function_entries is present and SHF_ALLOC (0x2)
reader = hui.Elf64Reader(binary_path)
sec = reader.by_name.get("__patchable_function_entries")
assert sec is not None, "ANTI-VACUITY FAILURE: __patchable_function_entries section is missing!"
assert (sec.flags & hui.SHF_ALLOC) != 0, \
    f"ANTI-VACUITY FAILURE: __patchable_function_entries is not SHF_ALLOC (flags=0x{sec.flags:x})"
assert sec.size > 0, "ANTI-VACUITY FAILURE: __patchable_function_entries is empty (0 bytes)!"

# Assert 3: Dynamic derivation and counts above non-vacuous floors
total_funcs = inv["totalDefinedFuncs"]
sled_count = inv["sledCount"]
unpatchable_count = inv["unpatchableCount"]

# Floor: libcodetracer_trace_writer.a alone contributes > 1600 functions
assert total_funcs >= 1650, f"totalDefinedFuncs {total_funcs} is below floor 1650"
assert unpatchable_count >= 1600, f"unpatchableCount {unpatchable_count} is below floor 1600"
assert sled_count >= 3, f"sledCount {sled_count} is below floor 3"
assert total_funcs == sled_count + unpatchable_count, \
    f"Sum mismatch: {total_funcs} != {sled_count} + {unpatchable_count}"

# Assert 4: BuildId is read dynamically from .note.gnu.build-id
build_id = inv["buildId"]
assert build_id and build_id != "unknown-build-id", f"buildId invalid: {build_id}"
real_build_id = reader.extract_build_id()
assert build_id == real_build_id, f"buildId mismatch: {build_id} vs {real_build_id}"

print(f"  [OK] Anti-vacuity: dynamic derivation confirmed:")
print(f"       totalDefinedFuncs={total_funcs}, sledCount={sled_count}, unpatchableCount={unpatchable_count}")
print(f"       __patchable_function_entries SHF_ALLOC verified (flags=0x{sec.flags:x}, size={sec.size})")
print(f"       buildId={build_id}")
EOF

# -----------------------------------------------------------------------------
# 5. Verification: Positive Arm and Control Arm
# -----------------------------------------------------------------------------
echo "[5/6] Running Positive Arm and Control Arm..."

# Positive Arm 1: Query ahead of time on an unsledded function from CTFS archive
echo "  Testing ahead-of-time query on unsledded function (ct_crossing_push)..."
QUERY_OUT_UNPATCHABLE="$("$INVENTORY_SCRIPT" "$TARGET_BIN" --archive "$CTFS_ARCHIVE" --query "ct_crossing_push")"
echo "$QUERY_OUT_UNPATCHABLE"
if ! echo "$QUERY_OUT_UNPATCHABLE" | grep -q "\[UNPATCHABLE\]"; then
  echo "FATAL: Query for ct_crossing_push did not report UNPATCHABLE" >&2
  exit 1
fi
if ! echo "$QUERY_OUT_UNPATCHABLE" | grep -q "absent-sled"; then
  echo "FATAL: Query for ct_crossing_push did not report refusal reason absent-sled" >&2
  exit 1
fi
if ! echo "$QUERY_OUT_UNPATCHABLE" | grep -q "libcodetracer_trace_writer.a"; then
  echo "FATAL: Query for ct_crossing_push did not attribute origin to libcodetracer_trace_writer.a" >&2
  exit 1
fi
echo "  [OK] Ahead-of-time query correctly identified ct_crossing_push as unpatchable absent-sled."

# Positive Arm 2: Real reload attempt on unsledded function MUST be refused absent-sled
echo "  Testing real reload attempt on unsledded function (ct_crossing_push)..."
set +e
"$INVENTORY_SCRIPT" "$TARGET_BIN" --attempt-reload "ct_crossing_push" > "$WORK_DIR/reload_ct_crossing_push.log" 2>&1
RELOAD_RC=$?
set -e
if [[ $RELOAD_RC -eq 0 ]]; then
  echo "FATAL: Reload attempt for ct_crossing_push unexpectedly succeeded!" >&2
  exit 1
fi
if ! grep -q "absent-sled" "$WORK_DIR/reload_ct_crossing_push.log"; then
  echo "FATAL: Reload refusal message did not name 'absent-sled'" >&2
  cat "$WORK_DIR/reload_ct_crossing_push.log" >&2
  exit 1
fi
echo "  [OK] Real reload attempt for ct_crossing_push was REFUSED with absent-sled."

# Positive Arm 3: Sledded function patches successfully
echo "  Testing real reload attempt on sledded function (patchable_victim)..."
"$INVENTORY_SCRIPT" "$TARGET_BIN" --attempt-reload "patchable_victim" > "$WORK_DIR/reload_patchable_victim.log" 2>&1
if ! grep -q "\[RELOAD-SUCCESS\]" "$WORK_DIR/reload_patchable_victim.log"; then
  echo "FATAL: Reload attempt for patchable_victim failed!" >&2
  cat "$WORK_DIR/reload_patchable_victim.log" >&2
  exit 1
fi
echo "  [OK] Real reload attempt for patchable_victim SUCCEEDED."

# Control Arm: Control sledded function (control_target)
echo "  Testing control arm on control_target..."
QUERY_OUT_CONTROL="$("$INVENTORY_SCRIPT" "$TARGET_BIN" --archive "$CTFS_ARCHIVE" --query "control_target")"
echo "$QUERY_OUT_CONTROL"
if ! echo "$QUERY_OUT_CONTROL" | grep -q "\[PATCHABLE\]"; then
  echo "FATAL: Control query for control_target did not report PATCHABLE" >&2
  exit 1
fi

# Assert control_target is ABSENT from the unpatchable inventory
python3 - "$INVENTORY_JSON" "control_target" << 'EOF'
import sys, json
inv_path, sym_name = sys.argv[1], sys.argv[2]
with open(inv_path, "r", encoding="utf-8") as f:
    inv = json.load(f)
unpatchable_names = {item["symbol"] for item in inv["unpatchableSymbols"]}
assert sym_name not in unpatchable_names, \
    f"CONTROL ARM FAILURE: sledded function '{sym_name}' is present in unpatchableSymbols!"
print(f"  [OK] Control function '{sym_name}' verified absent from unpatchable inventory.")
EOF

# Full Inventory Cross-Check: verify every item in inventory refuses absent-sled
echo "  Verifying full inventory artifact consistency against binary..."
"$INVENTORY_SCRIPT" "$TARGET_BIN" \
  --archive "$CTFS_ARCHIVE" \
  --verify-inventory "$INVENTORY_JSON"
echo "  [OK] Full inventory verification succeeded."

# -----------------------------------------------------------------------------
# 6. Verification: Falsifier Arm
# -----------------------------------------------------------------------------
if [[ $INCLUDE_FALSIFIER -eq 1 ]]; then
  echo "[6/6] Running Falsifier Arm (--include-falsifier)..."

  # Falsifier 1: Attribute an unsledded function to the wrong object
  echo "  [Falsifier 1] Mutating attribution of ct_crossing_push to wrong_object.o..."
  F1_JSON="$WORK_DIR/falsifier1_inventory.json"
  python3 - "$INVENTORY_JSON" "$F1_JSON" << 'EOF'
import sys, json
src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as f:
    data = json.load(f)
for item in data["unpatchableSymbols"]:
    if item["symbol"] == "ct_crossing_push":
        item["object"] = "wrong_object.o"
        break
with open(dst, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
EOF

  set +e
  "$INVENTORY_SCRIPT" "$TARGET_BIN" --archive "$CTFS_ARCHIVE" --verify-inventory "$F1_JSON" > "$WORK_DIR/f1.log" 2>&1
  F1_RC=$?
  set -e
  if [[ $F1_RC -eq 0 ]]; then
    echo "FATAL [FALSIFIER 1]: Corrupted attribution was NOT detected by inventory verification!" >&2
    exit 1
  fi
  if ! grep -q "Attribution mismatch" "$WORK_DIR/f1.log"; then
    echo "FATAL [FALSIFIER 1]: Error log did not report attribution mismatch:" >&2
    cat "$WORK_DIR/f1.log" >&2
    exit 1
  fi
  echo "  [OK] Falsifier 1 correctly caught attribution mismatch:"
  grep "Attribution mismatch" "$WORK_DIR/f1.log"

  # Falsifier 2: Add a sledded function to the unpatchable inventory
  echo "  [Falsifier 2] Injecting patchable function (patchable_victim) into unpatchable inventory..."
  F2_JSON="$WORK_DIR/f2_inventory.json"
  python3 - "$INVENTORY_JSON" "$F2_JSON" << 'EOF'
import sys, json
src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as f:
    data = json.load(f)
data["unpatchableSymbols"].insert(0, {
    "symbol": "patchable_victim",
    "address": "0x201200",
    "size": 32,
    "object": "target.o",
    "reason": "absent-sled"
})
with open(dst, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
EOF

  set +e
  "$INVENTORY_SCRIPT" "$TARGET_BIN" --archive "$CTFS_ARCHIVE" --verify-inventory "$F2_JSON" > "$WORK_DIR/f2.log" 2>&1
  F2_RC=$?
  set -e
  if [[ $F2_RC -eq 0 ]]; then
    echo "FATAL [FALSIFIER 2]: Sledded function falsely listed in inventory was NOT caught by reload verification!" >&2
    exit 1
  fi
  if ! grep -q "Reload SUCCEEDED for symbol 'patchable_victim'" "$WORK_DIR/f2.log"; then
    echo "FATAL [FALSIFIER 2]: Error log did not report unexpected reload success:" >&2
    cat "$WORK_DIR/f2.log" >&2
    exit 1
  fi
  echo "  [OK] Falsifier 2 correctly caught sledded function falsely declared unpatchable:"
  grep "Reload SUCCEEDED" "$WORK_DIR/f2.log"
else
  echo "[6/6] Skipping Falsifier Arm (pass --include-falsifier to run)."
fi

# -----------------------------------------------------------------------------
# Write Test Logs
# -----------------------------------------------------------------------------
LOG_DIR="$REPRO_ROOT/test-logs"
mkdir -p "$LOG_DIR"
RESULT_LOG="$LOG_DIR/integration_hx_l1_unpatchable_inventory.json"
cp "$INVENTORY_JSON" "$RESULT_LOG"
echo "Log written to $RESULT_LOG"

echo "=== Gate PASSED: hx_l1_the_unpatchable_set_is_inventoried_and_the_count_is_derived ==="
exit 0

#!/usr/bin/env bash
# test_hax_m1_binary_type_layout_diff_detects_field_shifts.sh
#
# Automated Integration Verification Gate for Milestone HAX-M1:
# "Pre-Flight Binary AST Type Layout Validation"
#
# Design doc: reprobuild-specs/HCR/Patch-Loading-Lifecycle.md §3
#             reprobuild-specs/HCR/Binary-Diffing-And-Symbol-Resolution.md §4
# Related milestones:
# - reprobuild-specs/HCR-Advanced-Lifecycle-And-Tooling.milestones.org (HAX-M1)
#
# Gate type: integration
# Real components:
# - Real binary AST type layout extractor (repro_hcr_linkgraph/type_layout)
# - Real DWARF debug info parsing from compiled relocatable object files
# - Real C compiler (clang) toolchain generating native Mach-O / ELF fixtures
# - Real type layout differential analysis and refusal classifier
#
# Allowed mocks: none
# Justification: Every use of mock objects in tests must be explicitly justified in the
# header comment of the test implementation file. We prefer strong integration tests that
# mock as little as possible and run against real filesystem, compiler, binary, and
# lifecycle execution boundaries. Mocks used: ZERO.
#
# Asserts:
# 1. Anti-vacuity: Type parser extracts exact member offsets (0, 4, 8) and member counts.
# 2. Control arm: Identical struct layout with altered function logic passes cleanly.
# 3. Positive arm: Altered function logic with identical struct layout passes validation cleanly.
# 4. Refusal arm: Struct member offset shift and field reordering refused with `type-layout-incompatible`
#    naming the struct, member, expected offset, and observed offset.
# 5. Falsifier: Simulates omitting member offset validation (--falsify-ignore-offset-shift),
#    causing incompatible patch to be accepted and triggering FALSIFIER-CAUGHT.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d /tmp/hax_m1_gate_XXXXXX)}"

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

echo "=== Gate: test_hax_m1_binary_type_layout_diff_detects_field_shifts ==="
echo "Working directory: $WORK_DIR"

# -----------------------------------------------------------------------------
# 1. Verify compiler availability
# -----------------------------------------------------------------------------
echo "[1/5] Checking compiler prerequisites..."
cd "$REPO_ROOT"

if ! command -v clang >/dev/null 2>&1; then
  echo "ERROR: clang compiler is required but not found in PATH" >&2
  exit 1
fi
if ! command -v nim >/dev/null 2>&1; then
  echo "ERROR: nim compiler is required but not found in PATH" >&2
  exit 1
fi
echo "  [OK] Compilers available: clang, nim."

# -----------------------------------------------------------------------------
# 2. Compile real C fixtures with baseline and mutated type layouts
# -----------------------------------------------------------------------------
echo "[2/5] Compiling real C object fixtures with DWARF debug info..."

BASE_C="$WORK_DIR/baseline.c"
CTRL_C="$WORK_DIR/control.c"
MUT_REORDER_C="$WORK_DIR/mut_reorder.c"
MUT_SHIFT_C="$WORK_DIR/mut_shift.c"

# Baseline: Vector3D (x@0, y@4, z@8), BitFlags (mode:4, state:4, tag@4)
cat << 'EOF' > "$BASE_C"
struct Vector3D {
    int x;
    int y;
    double z;
};

struct BitFlags {
    unsigned int mode : 4;
    unsigned int state : 4;
    int tag;
};

int vector_dot(struct Vector3D* v) {
    return v->x + v->y + (int)v->z;
}

int flag_check(struct BitFlags* f) {
    return (int)f->mode + f->tag;
}
EOF

# Control: Identical struct layout, altered function logic
cat << 'EOF' > "$CTRL_C"
struct Vector3D {
    int x;
    int y;
    double z;
};

struct BitFlags {
    unsigned int mode : 4;
    unsigned int state : 4;
    int tag;
};

int vector_dot(struct Vector3D* v) {
    return (v->x * 3) + (v->y * 5) + (int)(v->z * 2.0);
}

int flag_check(struct BitFlags* f) {
    return ((int)f->mode * 2) + f->tag + 10;
}
EOF

# Mutated 1: Reordered fields (y@0, x@4, z@8) - field swap & offset shift
cat << 'EOF' > "$MUT_REORDER_C"
struct Vector3D {
    int y;
    int x;
    double z;
};

struct BitFlags {
    unsigned int mode : 4;
    unsigned int state : 4;
    int tag;
};

int vector_dot(struct Vector3D* v) {
    return v->x + v->y + (int)v->z;
}

int flag_check(struct BitFlags* f) {
    return (int)f->mode + f->tag;
}
EOF

# Mutated 2: Inserted padding field shifting subsequent members (y@8, z@16) & size change
cat << 'EOF' > "$MUT_SHIFT_C"
struct Vector3D {
    int x;
    int pad;
    int y;
    double z;
};

struct BitFlags {
    unsigned int mode : 4;
    unsigned int state : 4;
    int tag;
};

int vector_dot(struct Vector3D* v) {
    return v->x + v->y + (int)v->z;
}

int flag_check(struct BitFlags* f) {
    return (int)f->mode + f->tag;
}
EOF

BASE_O="$WORK_DIR/baseline.o"
CTRL_O="$WORK_DIR/control.o"
MUT_REORDER_O="$WORK_DIR/mut_reorder.o"
MUT_SHIFT_O="$WORK_DIR/mut_shift.o"

clang -g -O0 -c "$BASE_C" -o "$BASE_O"
clang -g -O0 -c "$CTRL_C" -o "$CTRL_O"
clang -g -O0 -c "$MUT_REORDER_C" -o "$MUT_REORDER_O"
clang -g -O0 -c "$MUT_SHIFT_C" -o "$MUT_SHIFT_O"

for obj in "$BASE_O" "$CTRL_O" "$MUT_REORDER_O" "$MUT_SHIFT_O"; do
  if [[ ! -s "$obj" ]]; then
    echo "ERROR: Compiled object is missing or empty: $obj" >&2
    exit 1
  fi
done
echo "  [OK] Compiled real objects with DWARF debug info."

# -----------------------------------------------------------------------------
# 3. Build the integration test driver
# -----------------------------------------------------------------------------
echo "[3/5] Compiling Nim integration test driver..."

DRIVER_SRC="$REPO_ROOT/tests/integration/test_hax_m1_binary_type_layout_diff_detects_field_shifts.nim"
DRIVER_BIN="$WORK_DIR/test_hax_m1_driver"

nim c --hints:off --warnings:off \
  --nimcache:"$WORK_DIR/nimcache" \
  -o:"$DRIVER_BIN" \
  "$DRIVER_SRC"

echo "  [OK] Test driver compiled: $DRIVER_BIN"

# -----------------------------------------------------------------------------
# 4. Execute test driver: Anti-vacuity, Control, Positive, and Refusal arms
# -----------------------------------------------------------------------------
echo "[4/5] Running test driver (Anti-vacuity, Control, Refusal A, Refusal B)..."

"$DRIVER_BIN" "$BASE_O" "$CTRL_O" "$MUT_REORDER_O" "$MUT_SHIFT_O"

echo "  [OK] All test driver arms passed."

# -----------------------------------------------------------------------------
# 5. Falsifiers
# -----------------------------------------------------------------------------
if [[ $INCLUDE_FALSIFIER -eq 1 ]]; then
  echo "[5/5] Executing falsifier arm..."
  echo "  Testing Falsifier: Simulating omitting field offset validation (--falsify-ignore-offset-shift)..."

  set +e
  "$DRIVER_BIN" --falsify-ignore-offset-shift "$BASE_O" "$CTRL_O" "$MUT_REORDER_O" "$MUT_SHIFT_O" > "$WORK_DIR/falsifier.log" 2>&1
  FALSIFIER_RC=$?
  set -e

  if [[ $FALSIFIER_RC -eq 0 ]]; then
    echo "ERROR: Falsifier unexpectedly succeeded!" >&2
    exit 1
  fi

  if ! grep -q "FALSIFIER-CAUGHT" "$WORK_DIR/falsifier.log"; then
    echo "ERROR: Falsifier did not emit expected FALSIFIER-CAUGHT diagnostic!" >&2
    cat "$WORK_DIR/falsifier.log" >&2
    exit 1
  fi
  echo "  [OK] Falsifier caught: $(grep "FALSIFIER-CAUGHT" "$WORK_DIR/falsifier.log")"
else
  echo "[5/5] Falsifier execution skipped (pass --include-falsifier to enable)."
fi

echo ""
echo "=== Gate PASSED: test_hax_m1_binary_type_layout_diff_detects_field_shifts ==="

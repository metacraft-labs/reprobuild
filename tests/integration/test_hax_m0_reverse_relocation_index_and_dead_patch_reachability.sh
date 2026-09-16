#!/usr/bin/env bash
# test_hax_m0_reverse_relocation_index_and_dead_patch_reachability.sh
#
# Automated Integration Verification Gate for Milestone HAX-M0:
# "Relocation Reverse Reference Index and Multi-Generation Reachability"
#
# Design doc: reprobuild-specs/HCR/Incremental-Linker-Algorithm.md §5.3, §6
# Related milestones:
# - reprobuild-specs/HCR-Advanced-Lifecycle-And-Tooling.milestones.org (HAX-M0)
#
# Gate type: integration
# Real components:
# - Real reverse relocation reference index (refersTo / referredBy)
# - Real multi-generation reachability graph and transitive closure engine
# - Real compiled Mach-O / ELF relocatable object files
# - Real LinkGraph object parser (repro_hcr_linkgraph)
# - Real epoch-based region retirement and reclamation protocol
#
# Allowed mocks: none
# Justification: Every use of mock objects in tests must be explicitly justified in the
# header comment of the test implementation file. We prefer strong integration tests that
# mock as little as possible and run against real filesystem, compiler, binary, and
# lifecycle execution boundaries. Mocks used: ZERO.
#
# Asserts:
# 1. Exact reverse relocation site lookup across successive generations.
# 2. Reachability accurately marks dead helpers as unreachable when superseded.
# 3. Epoch advancement gates reclamation of unreachable regions.
# 4. Multi-generation chains maintain reachable roots and protected shared helpers.
# 5. Single-generation control arm maintains all allocated blocks as reachable.
# 6. Real Mach-O / ELF relocatable objects parse into LinkGraph and populate reverse index.
# 7. Falsifiers (--falsify-invert-reachability and --falsify-premature-reclaim) go red
#    and emit FALSIFIER-CAUGHT diagnostics.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d /tmp/hax_m0_gate_XXXXXX)}"

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

echo "=== Gate: test_hax_m0_reverse_relocation_index_and_dead_patch_reachability ==="
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
# 2. Compile real multi-generation relocatable object files
# -----------------------------------------------------------------------------
echo "[2/5] Compiling real multi-generation patch object files..."

GEN1_C="$WORK_DIR/gen1.c"
GEN2_C="$WORK_DIR/gen2.c"
GEN3_C="$WORK_DIR/gen3.c"

cat << 'EOF' > "$GEN1_C"
int helper_v1(int x) { return x + 1; }
int target_fn(int x) { return helper_v1(x); }
EOF

cat << 'EOF' > "$GEN2_C"
int helper_v2(int x) { return x + 2; }
int target_fn(int x) { return helper_v2(x); }
EOF

cat << 'EOF' > "$GEN3_C"
int helper_v3(int x) { return x + 3; }
int target_fn(int x) { return helper_v3(x); }
EOF

GEN1_O="$WORK_DIR/gen1.o"
GEN2_O="$WORK_DIR/gen2.o"
GEN3_O="$WORK_DIR/gen3.o"

clang -c -O0 -fno-inline "$GEN1_C" -o "$GEN1_O"
clang -c -O0 -fno-inline "$GEN2_C" -o "$GEN2_O"
clang -c -O0 -fno-inline "$GEN3_C" -o "$GEN3_O"

for obj in "$GEN1_O" "$GEN2_O" "$GEN3_O"; do
  if [[ ! -s "$obj" ]]; then
    echo "ERROR: Compiled object is missing or empty: $obj" >&2
    exit 1
  fi
done
echo "  [OK] Compiled real objects: gen1.o ($(wc -c < "$GEN1_O" | tr -d ' ') B), gen2.o ($(wc -c < "$GEN2_O" | tr -d ' ') B), gen3.o ($(wc -c < "$GEN3_O" | tr -d ' ') B)."

# -----------------------------------------------------------------------------
# 3. Build the integration test driver
# -----------------------------------------------------------------------------
echo "[3/5] Compiling Nim integration test driver..."

DRIVER_SRC="$REPO_ROOT/tests/integration/test_hax_m0_reverse_relocation_index_and_dead_patch_reachability.nim"
DRIVER_BIN="$WORK_DIR/test_hax_m0_driver"

nim c --hints:off --warnings:off \
  --nimcache:"$WORK_DIR/nimcache" \
  -o:"$DRIVER_BIN" \
  "$DRIVER_SRC"

echo "  [OK] Test driver compiled: $DRIVER_BIN"

# -----------------------------------------------------------------------------
# 4. Execute test driver: Positive arm, anti-vacuity, control arm, real objects
# -----------------------------------------------------------------------------
echo "[4/5] Running test driver (positive, reachability, epoch gating, control, real objects)..."

"$DRIVER_BIN" "$GEN1_O" "$GEN2_O" "$GEN3_O"

echo "  [OK] All driver checks passed."

# -----------------------------------------------------------------------------
# 5. Falsifiers
# -----------------------------------------------------------------------------
if [[ $INCLUDE_FALSIFIER -eq 1 ]]; then
  echo "[5/5] Executing falsifier arms..."

  echo "  Testing Falsifier 1: Simulating broken reachability traversal (--falsify-invert-reachability)..."
  set +e
  "$DRIVER_BIN" --falsify-invert-reachability "$GEN1_O" "$GEN2_O" "$GEN3_O" > "$WORK_DIR/falsifier1.log" 2>&1
  FALSIFIER1_RC=$?
  set -e

  if [[ $FALSIFIER1_RC -eq 0 ]]; then
    echo "ERROR: Falsifier 1 unexpectedly succeeded!" >&2
    exit 1
  fi

  if ! grep -q "FALSIFIER-CAUGHT" "$WORK_DIR/falsifier1.log"; then
    echo "ERROR: Falsifier 1 did not emit expected FALSIFIER-CAUGHT diagnostic!" >&2
    cat "$WORK_DIR/falsifier1.log" >&2
    exit 1
  fi
  echo "  [OK] Falsifier 1 caught: $(grep "FALSIFIER-CAUGHT" "$WORK_DIR/falsifier1.log")"

  echo "  Testing Falsifier 2: Simulating premature memory reclamation (--falsify-premature-reclaim)..."
  set +e
  "$DRIVER_BIN" --falsify-premature-reclaim "$GEN1_O" "$GEN2_O" "$GEN3_O" > "$WORK_DIR/falsifier2.log" 2>&1
  FALSIFIER2_RC=$?
  set -e

  if [[ $FALSIFIER2_RC -eq 0 ]]; then
    echo "ERROR: Falsifier 2 unexpectedly succeeded!" >&2
    exit 1
  fi

  if ! grep -q "FALSIFIER-CAUGHT" "$WORK_DIR/falsifier2.log"; then
    echo "ERROR: Falsifier 2 did not emit expected FALSIFIER-CAUGHT diagnostic!" >&2
    cat "$WORK_DIR/falsifier2.log" >&2
    exit 1
  fi
  echo "  [OK] Falsifier 2 caught: $(grep "FALSIFIER-CAUGHT" "$WORK_DIR/falsifier2.log")"
else
  echo "[5/5] Falsifier execution skipped (pass --include-falsifier to enable)."
fi

echo ""
echo "=== Gate PASSED: test_hax_m0_reverse_relocation_index_and_dead_patch_reachability ==="

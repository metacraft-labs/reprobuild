#!/usr/bin/env bash
# test_hx_s1_unwind_metadata_is_refused_rather_than_substituted.sh
#
# Automated Integration Gate for Milestone HX-S-1:
# "One unwind-metadata contract, three mechanisms"
#
# Design doc: reprobuild-specs/HCR/Debugger-Integration.md §5.6
# Gate type: integration
#
# Real components:
# - Real ELF objects compiled by clang for target x86_64-linux-gnu:
#     * Positive arm: compiled with unwind tables and DWARF (-g -fPIC)
#     * Refusal arm A: compiled with -fno-asynchronous-unwind-tables -fno-unwind-tables
#     * Refusal arm B: real object stripped of .eh_frame via llvm-objcopy
# - Real coordinator metadata path: hcrUnwindMetadataFor (repro_cli_support.nim)
# - Real linkgraph object reader: parseElfX86_64Object (repro_hcr_linkgraph/elf.nim)
# - Real template reference: minimalAarch64EhFrameTemplate (debug_unwind.nim)
#
# Allowed mocks: none.
#
# Asserts:
# 1. Positive / control arm:
#    When given a valid patch object carrying real unwind metadata (.eh_frame),
#    hcrUnwindMetadataFor returns the non-empty section bytes matching the section payload,
#    and does NOT equal minimalAarch64EhFrameTemplate().
# 2. Refusal arm:
#    When given an object stripped of .eh_frame (or built with -fno-asynchronous-unwind-tables),
#    hcrUnwindMetadataFor REFUSES BY NAME with an exception explicitly naming .eh_frame
#    (does not return an empty slice and does not return the synthetic template).
# 3. Falsifier (--include-falsifier):
#    Simulates reinstating the fallback (returning minimalAarch64EhFrameTemplate()
#    when unwind data is missing). The harness asserts that the returned bytes are NOT
#    the 64-byte template, asserting against the template's known 64 bytes
#    (0x10, 0x00, 0x00, 0x00, ...), so a byte-identical coincidence cannot pass.
# 4. Anti-vacuity:
#    - Asserts the positive arm object DOES carry unwind data (.eh_frame is non-empty
#      and matches independently parsed bytes).
#    - Asserts the returned payload is non-empty and equal to the section data.
#    - Asserts the profile under test is genuinely the ELF profile (linux-x86_64).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d /tmp/hx_s1_gate_XXXXXX)}"

INCLUDE_FALSIFIER=0
for arg in "$@"; do
  case "$arg" in
    --include-falsifier|--falsifier)
      INCLUDE_FALSIFIER=1
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

echo "=== Gate: hx_s1_unwind_metadata_is_refused_rather_than_substituted ==="
echo "Working directory: $WORK_DIR"

# -----------------------------------------------------------------------------
# 1. Source environment paths and verify compiler / toolchain availability
# -----------------------------------------------------------------------------
echo "[1/5] Checking toolchain prerequisites and resolving paths..."

cd "$REPO_ROOT"

if [[ -f "scripts/source_paths.sh" ]]; then
  # shellcheck source=scripts/source_paths.sh
  source "scripts/source_paths.sh"
  if [[ -z "${BEARSSL_SRC:-}" ]]; then
    export BEARSSL_SRC="$(resolve_bearssl_src)"
  fi
  if [[ -z "${SHM_QUEUE_SRC:-}" ]]; then
    export SHM_QUEUE_SRC="$(resolve_shm_queue_src)"
  fi
fi

if ! command -v clang >/dev/null 2>&1; then
  echo "ERROR: clang compiler is required but not found in PATH" >&2
  exit 1
fi

if ! command -v objcopy >/dev/null 2>&1; then
  echo "ERROR: objcopy is required but not found in PATH" >&2
  exit 1
fi

C_FIXTURE="$REPO_ROOT/tests/fixtures/hcr/linux-elf-objects/hcr_lx_obj_gen1.c"
if [[ ! -f "$C_FIXTURE" ]]; then
  echo "ERROR: C fixture missing at $C_FIXTURE" >&2
  exit 1
fi
echo "  [OK] Toolchain and fixtures available."

# -----------------------------------------------------------------------------
# 2. Compile real ELF x86_64 patch objects and Mach-O arm64 patch objects
# -----------------------------------------------------------------------------
echo "[2/5] Compiling real ELF x86_64 and Mach-O arm64 patch objects..."

UNWIND_O="$WORK_DIR/gen1_unwind.o"
NOUNWIND_O="$WORK_DIR/gen1_nounwind.o"
STRIPPED_O="$WORK_DIR/gen1_stripped.o"
MAC_UNWIND_O="$WORK_DIR/mac_gen1_unwind.o"
MAC_NOUNWIND_O="$WORK_DIR/mac_gen1_nounwind.o"

# Arm 1: Positive arm with asynchronous unwind tables (.eh_frame)
clang -target x86_64-linux-gnu -O2 -g -fPIC -ffunction-sections -fdata-sections \
  -c "$C_FIXTURE" -o "$UNWIND_O"

# Arm 2: Object compiled without unwind tables (-fno-asynchronous-unwind-tables)
clang -target x86_64-linux-gnu -O2 -fno-asynchronous-unwind-tables -fno-unwind-tables \
  -fPIC -ffunction-sections -fdata-sections \
  -c "$C_FIXTURE" -o "$NOUNWIND_O"

# Arm 3: Object with .eh_frame explicitly stripped via objcopy
cp "$UNWIND_O" "$STRIPPED_O"
objcopy --remove-section .eh_frame "$STRIPPED_O"

# An explicit deployment target is required for the fixture's thread-local data.
clang -target arm64-apple-macos11.0 -O2 -g -fasynchronous-unwind-tables \
  -c "$C_FIXTURE" -o "$MAC_UNWIND_O"

clang -target arm64-apple-macos11.0 -O2 -fno-asynchronous-unwind-tables -fno-unwind-tables \
  -c "$C_FIXTURE" -o "$MAC_NOUNWIND_O"

for obj in "$UNWIND_O" "$NOUNWIND_O" "$STRIPPED_O" "$MAC_UNWIND_O" "$MAC_NOUNWIND_O"; do
  if [[ ! -s "$obj" ]]; then
    echo "ERROR: Compiled object is missing or empty: $obj" >&2
    exit 1
  fi
done

echo "  [OK] Real objects produced: ELF positive ($(wc -c < "$UNWIND_O" | tr -d ' ') bytes), no-unwind ($(wc -c < "$NOUNWIND_O" | tr -d ' ') bytes), stripped ($(wc -c < "$STRIPPED_O" | tr -d ' ') bytes), Mach-O positive ($(wc -c < "$MAC_UNWIND_O" | tr -d ' ') bytes), Mach-O no-unwind ($(wc -c < "$MAC_NOUNWIND_O" | tr -d ' ') bytes)."

# -----------------------------------------------------------------------------
# 3. Build the integration test driver
# -----------------------------------------------------------------------------
echo "[3/5] Compiling Nim integration test driver..."

DRIVER_SRC="$REPO_ROOT/tests/fixtures/hcr/unwind_metadata_driver.nim"
DRIVER_BIN="$WORK_DIR/test_hx_s1_driver"

nim c --hints:off --warnings:off \
  --nimcache:"$WORK_DIR/nimcache" \
  -o:"$DRIVER_BIN" \
  "$DRIVER_SRC"

echo "  [OK] Test driver compiled."

# -----------------------------------------------------------------------------
# 4. Execute test driver: Positive arm, refusal arm, and anti-vacuity floors
# -----------------------------------------------------------------------------
echo "[4/5] Running test driver (positive arm, refusal arm, anti-vacuity)..."

"$DRIVER_BIN" "$UNWIND_O" "$NOUNWIND_O" "$STRIPPED_O" "$MAC_UNWIND_O" "$MAC_NOUNWIND_O"

echo "  [OK] All driver checks passed."

# -----------------------------------------------------------------------------
# 5. Falsifiers
# -----------------------------------------------------------------------------
if [[ $INCLUDE_FALSIFIER -eq 1 ]]; then
  echo "[5/5] Executing falsifier arms..."

  echo "  Testing Falsifier: Simulating fallback substitution of minimalAarch64EhFrameTemplate()..."
  set +e
  "$DRIVER_BIN" --falsify-fallback "$UNWIND_O" "$NOUNWIND_O" "$STRIPPED_O" "$MAC_UNWIND_O" "$MAC_NOUNWIND_O" > "$WORK_DIR/falsifier.log" 2>&1
  FALSIFIER_RC=$?
  set -e

  if [[ $FALSIFIER_RC -eq 0 ]]; then
    echo "ERROR: Falsifier unexpectedly succeeded when fallback substitution was simulated!" >&2
    exit 1
  fi

  if ! grep -q "FALSIFIER-CAUGHT" "$WORK_DIR/falsifier.log"; then
    echo "ERROR: Falsifier did not emit expected FALSIFIER-CAUGHT diagnostic!" >&2
    cat "$WORK_DIR/falsifier.log" >&2
    exit 1
  fi

  echo "  [OK] Falsifier went red with exit code $FALSIFIER_RC as expected:"
  echo "       $(grep "FALSIFIER-CAUGHT" "$WORK_DIR/falsifier.log")"
else
  echo "[5/5] Falsifier execution skipped (pass --include-falsifier to enable)."
fi

echo ""
echo "=== Gate PASSED: hx_s1_unwind_metadata_is_refused_rather_than_substituted ==="

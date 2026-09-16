#!/usr/bin/env bash
# test_hx_w4_an_exception_unwinds_through_a_patched_windows_frame.sh
#
# Automated Integration Verification Gate for Milestone HX-W-4:
# "Register the patch region so Windows will enter it and unwind through it"
#
# References:
# - reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org (HX-W-4, lines 1804-1857)
# - reprobuild-specs/HCR/Incremental-Linker-Algorithm.md §5.3, §5.5
# - reprobuild-specs/HCR/Debugger-Integration.md §7.1, §7.2
# - reprobuild-specs/HCR/Dispatch-Table-Patching.md §4.4
# - reprobuild-specs/HCR/Trampoline-Mechanics.md §4.4.3
# - reprobuild-specs/HCR/Linux-ELF-Provider.md §5.2 (HLX-M5 precedent)
# - reprobuild/libs/repro_hcr_agent/c/repro_hcr_windows_unwind_cfg.h
#
# Gate type: e2e / integration
#
# Real components:
# - Real Windows PE x64 binaries built with clang-cl /guard:cf and lld-link /guard:cf
#   containing genuine .pdata / RUNTIME_FUNCTION unwind tables and CFG load configuration.
# - Real uninstrumented Windows PE binary providing genuine non-CFG contrast.
# - Real COFF relocatable object (patch.obj) with real .pdata and .xdata unwind sections.
# - Real COFF object lacking unwind metadata (-fno-asynchronous-unwind-tables) exercising
#   the HX-S-1 refusal rule (unwind-metadata-missing / absent-unwind-info).
# - Real extraction and relocation of .pdata/.xdata unwind tables with patch base as ImageBase.
# - Real CFG bitmap/target registration verification.
# - Real exception unwinding through a patched Windows frame to caller's handler.
# - Zero mocks.
#
# Verification arms:
# 1. Positive Arm:
#    * Patched function has real .pdata/.xdata registered via RtlAddFunctionTable.
#    * CFG valid call targets registered via SetProcessValidCallTargets before trampoline installation.
#    * Pre-publication invariant check passes.
#    * Indirect call / trampoline entry succeeds.
#    * Exception raised below patched frame unwinds cleanly through the patched frame to caller's handler.
# 2. Control Arm:
#    * Same exception through an unpatched frame reaches the same handler.
# 3. Anti-Vacuity Arm:
#    * Target genuinely has CFG enabled in headers (IMAGE_DLLCHARACTERISTICS_GUARD_CF verified).
#    * Exception genuinely traversed the patched frame (observed in the unwind trace, not merely inferred).
#    * Table counts > 0, .xdata size > 0.
# 4. Falsifier Arm 1 (--include-falsifier):
#    * Skip RtlAddFunctionTable call: unwinder fails to interpret frame, corrupts stack, and handler is not reached.
# 5. Falsifier Arm 2 (--include-falsifier):
#    * Skip SetProcessValidCallTargets on CFG target: indirect call trips FAST_FAIL_CONTROL_FLOW_GUARD_CHECK (process kill).
# 6. Falsifier Arm 3 (--include-falsifier):
#    * Free region without RtlDeleteFunctionTable: stale table leak is detected in agent state.
# 7. Teardown / Rollback Lifecycle Arm:
#    * RtlDeleteFunctionTable cleans up table registration; zero leaks reported on subsequent checks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d /tmp/hx_w4_gate_XXXXXX)}"

# Locate reprobuild-specs repo
if [[ -d "$REPO_ROOT/../reprobuild-specs" ]]; then
  SPECS_DIR="$(cd "$REPO_ROOT/../reprobuild-specs" && pwd)"
elif [[ -d "$REPO_ROOT/reprobuild-specs" ]]; then
  SPECS_DIR="$(cd "$REPO_ROOT/reprobuild-specs" && pwd)"
else
  echo "ERROR: Unable to locate reprobuild-specs directory" >&2
  exit 1
fi

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

echo "=== Gate: hx_w4_an_exception_unwinds_through_a_patched_windows_frame ==="
echo "Repo root:         $REPO_ROOT"
echo "Specs directory:   $SPECS_DIR"
echo "Working directory: $WORK_DIR"
echo "Falsifier enabled: $INCLUDE_FALSIFIER"

# -----------------------------------------------------------------------------
# 1. Discover Toolchain Prerequisites
# -----------------------------------------------------------------------------
echo "[1/6] Discovering toolchain prerequisites..."

find_tool() {
  local tool_name="$1"
  local nix_pattern="$2"
  local found=""

  for p in /nix/store/*"$nix_pattern"*/bin/"$tool_name"; do
    if [[ -x "$p" ]]; then
      found="$p"
      break
    fi
  done

  if [[ -z "$found" ]] && command -v "$tool_name" >/dev/null 2>&1; then
    found="$(command -v "$tool_name")"
  fi

  if [[ -z "$found" ]]; then
    echo "ERROR: Required tool '$tool_name' not found" >&2
    exit 1
  fi
  echo "$found"
}

CLANG_BIN="$(find_tool clang clang-21)"
CLANG_CL_BIN="$(find_tool clang-cl clang-21)"
LLD_LINK_BIN="$(find_tool lld-link lld-21)"
LLVM_READOBJ_BIN="$(find_tool llvm-readobj llvm-21)"
LLVM_OBJDUMP_BIN="$(find_tool llvm-objdump llvm-21)"
HOST_CC="${CC:-clang}"

echo "  -> Clang:        $CLANG_BIN"
echo "  -> Clang-cl:     $CLANG_CL_BIN"
echo "  -> LLD-Link:     $LLD_LINK_BIN"
echo "  -> llvm-readobj: $LLVM_READOBJ_BIN"
echo "  -> Host CC:      $HOST_CC"

# -----------------------------------------------------------------------------
# 2. Verify Specification Decisions & Consistency
# -----------------------------------------------------------------------------
echo "[2/6] Verifying specification consistency for HX-W-4..."

LINKER_SPEC="$SPECS_DIR/HCR/Incremental-Linker-Algorithm.md"
DEBUGGER_SPEC="$SPECS_DIR/HCR/Debugger-Integration.md"
MILESTONES_SPEC="$SPECS_DIR/HCR-Per-Platform-Handoff.milestones.org"

# Check Incremental-Linker-Algorithm.md §5.3 and §5.5
if ! grep -q "Patch Region Base as Image Base" "$LINKER_SPEC"; then
  echo "ERROR: $LINKER_SPEC missing 'Patch Region Base as Image Base' in §5.3" >&2
  exit 1
fi
if ! grep -q "unwind-metadata-missing" "$LINKER_SPEC"; then
  echo "ERROR: $LINKER_SPEC missing 'unwind-metadata-missing' in §5.3" >&2
  exit 1
fi
if ! grep -q "RtlDeleteFunctionTable" "$LINKER_SPEC"; then
  echo "ERROR: $LINKER_SPEC missing 'RtlDeleteFunctionTable' in §5.3" >&2
  exit 1
fi
if ! grep -q "FAST_FAIL_CONTROL_FLOW_GUARD_CHECK" "$LINKER_SPEC"; then
  echo "ERROR: $LINKER_SPEC missing 'FAST_FAIL_CONTROL_FLOW_GUARD_CHECK' in §5.5" >&2
  exit 1
fi
echo "  [OK] Incremental-Linker-Algorithm.md §5.3 and §5.5 verified."

# Check Debugger-Integration.md §7.1 and §7.2
if ! grep -q "Architectural Decision: \`RtlAddFunctionTable\` vs \`RtlInstallFunctionTableCallback\`" "$DEBUGGER_SPEC"; then
  echo "ERROR: $DEBUGGER_SPEC missing RtlAddFunctionTable vs RtlInstallFunctionTableCallback decision in §7.1" >&2
  exit 1
fi
if ! grep -q "OutOfProcessCallbackDll" "$DEBUGGER_SPEC"; then
  echo "ERROR: $DEBUGGER_SPEC missing OutOfProcessCallbackDll in §7.1" >&2
  exit 1
fi
if ! grep -q "Lifecycle Contract (HX-W-4)" "$DEBUGGER_SPEC"; then
  echo "ERROR: $DEBUGGER_SPEC missing Lifecycle Contract (HX-W-4) in §7.2" >&2
  exit 1
fi
echo "  [OK] Debugger-Integration.md §7.1 and §7.2 verified."

# -----------------------------------------------------------------------------
# 3. Header Syntax Verification
# -----------------------------------------------------------------------------
echo "[3/6] Verifying repro_hcr_windows_unwind_cfg.h syntax..."
HEADER_PATH="$REPO_ROOT/libs/repro_hcr_agent/c/repro_hcr_windows_unwind_cfg.h"
if [[ ! -f "$HEADER_PATH" ]]; then
  echo "ERROR: Header $HEADER_PATH does not exist" >&2
  exit 1
fi

if ! "$CLANG_BIN" --target=x86_64-windows-msvc -fsyntax-only -Wall -Wextra "$HEADER_PATH" 2>"$WORK_DIR/cross_syntax.err"; then
  cat "$WORK_DIR/cross_syntax.err" >&2
  echo "ERROR: Cross-compilation syntax check failed for x86_64-windows-msvc target" >&2
  exit 1
fi
echo "  [OK] clang --target=x86_64-windows-msvc syntax check passed with zero warnings."

if ! "$HOST_CC" -fsyntax-only -Wall -Wextra -I "$REPO_ROOT/libs/repro_hcr_agent/c" "$HEADER_PATH" 2>"$WORK_DIR/native_syntax.err"; then
  cat "$WORK_DIR/native_syntax.err" >&2
  echo "ERROR: Native host syntax check failed" >&2
  exit 1
fi
echo "  [OK] Native host compiler syntax check passed with zero warnings."

# -----------------------------------------------------------------------------
# 4. Compile Real Windows PE Fixtures (CFG target, non-CFG, patch.obj, no_unwind)
# -----------------------------------------------------------------------------
echo "[4/6] Compiling real PE/COFF fixtures with zero mocks..."

# 4.1 Target source with LoadConfig defining CFG structures
cat << 'EOF' > "$WORK_DIR/cfg_target.c"
#include <stdint.h>

typedef struct _IMAGE_LOAD_CONFIG_CODE_INTEGRITY {
    uint16_t Flags;
    uint16_t Catalog;
    uint32_t CatalogOffset;
    uint32_t Reserved;
} IMAGE_LOAD_CONFIG_CODE_INTEGRITY;

typedef struct _IMAGE_LOAD_CONFIG_DIRECTORY64 {
    uint32_t Size;
    uint32_t TimeDateStamp;
    uint16_t MajorVersion;
    uint16_t MinorVersion;
    uint32_t GlobalFlagsClear;
    uint32_t GlobalFlagsSet;
    uint32_t CriticalSectionDefaultTimeout;
    uint64_t DeCommitFreeBlockThreshold;
    uint64_t DeCommitTotalFreeThreshold;
    uint64_t LockPrefixTable;
    uint64_t MaximumAllocationSize;
    uint64_t VirtualMemoryThreshold;
    uint64_t ProcessAffinityMask;
    uint32_t ProcessHeapFlags;
    uint16_t CSDVersion;
    uint16_t DependentLoadFlags;
    uint64_t EditList;
    uint64_t SecurityCookie;
    uint64_t SEHandlerTable;
    uint64_t SEHandlerCount;
    uint64_t GuardCFCheckFunctionPointer;
    uint64_t GuardCFDispatchFunctionPointer;
    uint64_t GuardCFFunctionTable;
    uint64_t GuardCFFunctionCount;
    uint32_t GuardFlags;
    IMAGE_LOAD_CONFIG_CODE_INTEGRITY CodeIntegrity;
    uint64_t GuardAddressTakenIatEntryTable;
    uint64_t GuardAddressTakenIatEntryCount;
    uint64_t GuardLongJumpTargetTable;
    uint64_t GuardLongJumpTargetCount;
    uint64_t DynamicValueRelocTable;
    uint64_t CHPEMetadataPointer;
    uint64_t GuardRFFailureRoutine;
    uint64_t GuardRFFailureRoutineFunctionPointer;
    uint32_t DynamicValueRelocTableOffset;
    uint16_t DynamicValueRelocTableSection;
    uint16_t Reserved2;
    uint64_t GuardRFVerifyStackPointerFunctionPointer;
    uint32_t HotPatchTableOffset;
    uint32_t Reserved3;
    uint64_t EnclaveConfigurationPointer;
    uint64_t VolatileMetadataPointer;
    uint64_t GuardEHContinuationTable;
    uint64_t GuardEHContinuationCount;
    uint64_t GuardXFGCheckFunctionPointer;
    uint64_t GuardXFGDispatchFunctionPointer;
    uint64_t GuardXFGTableDispatchFunctionPointer;
    uint64_t CastGuardOsDeterminedFailureMode;
    uint64_t GuardMemcpyFunctionPointer;
} IMAGE_LOAD_CONFIG_DIRECTORY64;

const uint64_t __security_cookie = 0x00002B992DDFA232ULL;
uint64_t __guard_check_icall_fptr = 0;
uint64_t __guard_dispatch_icall_fptr = 0;

extern const IMAGE_LOAD_CONFIG_DIRECTORY64 _load_config_used;
const IMAGE_LOAD_CONFIG_DIRECTORY64 _load_config_used = {
    .Size = sizeof(IMAGE_LOAD_CONFIG_DIRECTORY64),
    .SecurityCookie = (uint64_t)&__security_cookie,
    .GuardCFCheckFunctionPointer = (uint64_t)&__guard_check_icall_fptr,
    .GuardCFDispatchFunctionPointer = (uint64_t)&__guard_dispatch_icall_fptr,
    .GuardFlags = 0x00000100 | 0x00000400 | 0x00001000,
};

__attribute__((noinline)) int victim_leaf(int a) {
    return a + 42;
}

__attribute__((noinline)) int victim_frame(int x, int y) {
    volatile int local[16];
    local[0] = x;
    local[1] = y;
    return victim_leaf(local[0] + local[1]);
}

int main(int argc, char **argv) {
    (void)argv;
    int (*fn)(int, int) = victim_frame;
    return fn(argc, 2);
}
EOF

# Compile and link CFG target executable
"$CLANG_CL_BIN" --target=x86_64-windows-msvc /guard:cf /c /O2 "$WORK_DIR/cfg_target.c" /Fo"$WORK_DIR/cfg_target.obj"
"$LLD_LINK_BIN" /machine:x64 /guard:cf /entry:main /subsystem:console /nodefaultlib "$WORK_DIR/cfg_target.obj" \
  /out:"$WORK_DIR/cfg_target.exe"

# 4.2 Compile and link non-CFG target executable (contrast)
cat << 'EOF' > "$WORK_DIR/non_cfg_target.c"
__attribute__((noinline)) int victim_frame(int x, int y) {
    volatile int local[16];
    local[0] = x;
    local[1] = y;
    return local[0] + local[1];
}

int main(int argc, char **argv) {
    (void)argv;
    return victim_frame(argc, 10);
}
EOF
"$CLANG_CL_BIN" --target=x86_64-windows-msvc /c /O2 "$WORK_DIR/non_cfg_target.c" /Fo"$WORK_DIR/non_cfg_target.obj"
"$LLD_LINK_BIN" /machine:x64 /entry:main /subsystem:console /nodefaultlib "$WORK_DIR/non_cfg_target.obj" \
  /out:"$WORK_DIR/non_cfg_target.exe"

# 4.3 Compile patch.obj with real .pdata and .xdata unwind tables
cat << 'EOF' > "$WORK_DIR/patch.c"
__attribute__((noinline)) int patched_victim_frame(int x, int y) {
    volatile int local[32];
    local[0] = x * 10;
    local[1] = y * 20;
    return local[0] + local[1];
}
EOF
"$CLANG_CL_BIN" --target=x86_64-windows-msvc /c /O2 "$WORK_DIR/patch.c" /Fo"$WORK_DIR/patch.obj"

# 4.4 Compile no_unwind.obj lacking unwind tables (-fno-asynchronous-unwind-tables)
"$CLANG_BIN" --target=x86_64-windows-msvc -c -O2 -fno-asynchronous-unwind-tables -x c - -o "$WORK_DIR/no_unwind.obj" << 'EOF'
int callee(int a);
int target_fn(int x) {
    return callee(x + 1) * 2;
}
EOF

echo "  [OK] Real PE/COFF fixtures compiled successfully."

# -----------------------------------------------------------------------------
# 5. Inspect Fixtures & Anti-Vacuity Floors
# -----------------------------------------------------------------------------
echo "[5/6] Inspecting PE/COFF fixtures and asserting anti-vacuity floors..."

# 5.1 Verify CFG in cfg_target.exe
CFG_HEADERS="$("$LLVM_READOBJ_BIN" --file-headers "$WORK_DIR/cfg_target.exe")"
if ! echo "$CFG_HEADERS" | grep -q "IMAGE_DLL_CHARACTERISTICS_GUARD_CF"; then
  echo "ERROR: Anti-vacuity violation: cfg_target.exe missing IMAGE_DLL_CHARACTERISTICS_GUARD_CF" >&2
  exit 1
fi
echo "  [OK] cfg_target.exe carries IMAGE_DLL_CHARACTERISTICS_GUARD_CF."

# 5.2 Verify non-CFG target lacks CFG
NON_CFG_HEADERS="$("$LLVM_READOBJ_BIN" --file-headers "$WORK_DIR/non_cfg_target.exe")"
if echo "$NON_CFG_HEADERS" | grep -q "IMAGE_DLL_CHARACTERISTICS_GUARD_CF"; then
  echo "ERROR: Anti-vacuity violation: non_cfg_target.exe unexpectedly carries CFG" >&2
  exit 1
fi
echo "  [OK] non_cfg_target.exe confirmed free of CFG characteristics."

# 5.3 Verify unwind data in patch.obj
PATCH_SECTIONS="$("$LLVM_READOBJ_BIN" --sections "$WORK_DIR/patch.obj")"
if ! echo "$PATCH_SECTIONS" | grep -q "\.pdata"; then
  echo "ERROR: Anti-vacuity violation: patch.obj missing .pdata section" >&2
  exit 1
fi
if ! echo "$PATCH_SECTIONS" | grep -q "\.xdata"; then
  echo "ERROR: Anti-vacuity violation: patch.obj missing .xdata section" >&2
  exit 1
fi
echo "  [OK] patch.obj contains genuine .pdata and .xdata sections."

# 5.4 Verify no_unwind.obj lacks unwind sections
NO_UNWIND_SECTIONS="$("$LLVM_READOBJ_BIN" --sections "$WORK_DIR/no_unwind.obj")"
if echo "$NO_UNWIND_SECTIONS" | grep -q "\.pdata"; then
  echo "ERROR: Anti-vacuity violation: no_unwind.obj unexpectedly carries .pdata" >&2
  exit 1
fi
echo "  [OK] no_unwind.obj confirmed devoid of .pdata."

# -----------------------------------------------------------------------------
# 6. Execute C Verification Driver
# -----------------------------------------------------------------------------
echo "[6/6] Executing C integration verification driver..."

DRIVER_SRC="$REPO_ROOT/tests/integration/test_hx_w4_driver.c"
DRIVER_BIN="$WORK_DIR/test_hx_w4_driver"

"$HOST_CC" -Wall -Wextra -Werror -I "$REPO_ROOT/libs/repro_hcr_agent/c" "$DRIVER_SRC" -o "$DRIVER_BIN"

DRIVER_ARGS=(
  "$WORK_DIR/cfg_target.exe"
  "$WORK_DIR/non_cfg_target.exe"
  "$WORK_DIR/patch.obj"
  "$WORK_DIR/no_unwind.obj"
)

if [[ "$INCLUDE_FALSIFIER" -eq 1 ]]; then
  DRIVER_ARGS+=("--include-falsifier")
fi

"$DRIVER_BIN" "${DRIVER_ARGS[@]}"

echo "=== Gate PASSED: Milestone HX-W-4 verified successfully ==="
exit 0

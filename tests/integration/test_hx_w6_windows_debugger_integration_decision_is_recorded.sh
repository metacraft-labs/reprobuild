#!/usr/bin/env bash
# test_hx_w6_windows_debugger_integration_decision_is_recorded.sh
#
# Automated Integration Verification Gate for Milestone HX-W-6:
# "Decide the Windows debugger integration, including what is refused"
#
# References:
# - reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org (HX-W-6, lines 1907-1961)
# - reprobuild-specs/HCR/Debugger-Integration.md §7.1, §7.3, §7.4, §7.5, §7.7, §7.8, §8.4
# - reprobuild-specs/HCR/HCR-Overview.md §14.3, §15
# - reprobuild/libs/repro_hcr_agent/c/repro_hcr_windows_debug.h
# - reprobuild/libs/repro_hcr_agent/c/repro_hcr_windows_pe.h
# - reprobuild/libs/repro_hcr_agent/scripts/reprobuild_hcr.js
#
# Gate type: integration / e2e decision
#
# Real components:
# - Real baseline Windows PE x86_64 executable (target_app.exe) with matching PDB (target_app.pdb).
# - Real patch PE x86_64 DLL (patch_mod.dll) with matching PDB (patch_mod.pdb).
# - Real synthesized minimal PE header generated in memory and inspected via llvm-readobj.
# - Real CV_INFO_PDB70 RSDS record verification with real GUID and Age matching.
# - Real .pdata exception directory entry in synthesized PE header.
# - Real WinDbg .reload command formulation and WinDbg JS extension syntax check.
# - Real Visual Studio Concord standing refusal check.
# - Zero mocks.
#
# Verification arms:
# 1. Positive Arm:
#    * Synthesized PE header carries valid DOS header, NT headers, machine=0x8664.
#    * Debug directory points to CV_INFO_PDB70 with RSDS (0x53445352), valid GUID, matching age.
#    * Exception directory points to .pdata entries inside patch memory.
#    * WinDbg .reload command formatted cleanly and JS extension handles it.
# 2. Anti-Vacuity Arm:
#    * Synthesized header bytes are validated in memory and parsed as a genuine PE image.
#    * GUID has non-zero bytes; age > 0.
#    * WinDbg JS extension file exists and contains load script functions.
# 3. Control Arm:
#    * Unpatched baseline resolves from on-disk primary image PDB.
#    * Direct patch injection under Visual Studio Concord is explicitly REFUSED with
#      refused-visual-studio-direct-debugging (decision recorded, not attempted and failed).
# 4. Falsifier Arms (--include-falsifier):
#    * Falsifier 1: Corrupt PDB GUID in synthesized CodeView record -> caught by mismatch verification.
#    * Falsifier 2: Corrupt PDB Age in synthesized CodeView record -> caught by age mismatch verification.
#    * Falsifier 3: Falsely allow Visual Studio under direct patch mode -> caught by refusal invariant assertion.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d /tmp/hx_w6_gate_XXXXXX)}"

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

echo "=== Gate: hx_w6_windows_debugger_integration_decision_is_recorded ==="
echo "Repo root:         $REPO_ROOT"
echo "Specs directory:   $SPECS_DIR"
echo "Working directory: $WORK_DIR"
echo "Falsifier enabled: $INCLUDE_FALSIFIER"

# -----------------------------------------------------------------------------
# 1. Discover Toolchain Prerequisites
# -----------------------------------------------------------------------------
echo "[1/7] Discovering toolchain prerequisites..."

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
LLD_LINK_BIN="$(find_tool lld-link lld-21)"
LLVM_READOBJ_BIN="$(find_tool llvm-readobj llvm-21)"
NODE_BIN="$(command -v node || find_tool node node)"
HOST_CC="${CC:-/usr/bin/clang}"

echo "  -> Clang:        $CLANG_BIN"
echo "  -> LLD-Link:     $LLD_LINK_BIN"
echo "  -> llvm-readobj: $LLVM_READOBJ_BIN"
echo "  -> Node:         $NODE_BIN"
echo "  -> Host CC:      $HOST_CC"

# -----------------------------------------------------------------------------
# 2. Verify Specification Decisions & Consistency
# -----------------------------------------------------------------------------
echo "[2/7] Verifying specification consistency for HX-W-6..."

DEBUGGER_SPEC="$SPECS_DIR/HCR/Debugger-Integration.md"
OVERVIEW_SPEC="$SPECS_DIR/HCR/HCR-Overview.md"
MILESTONES_SPEC="$SPECS_DIR/HCR-Per-Platform-Handoff.milestones.org"

# Check Debugger-Integration.md
if ! grep -q "refused-visual-studio-direct-debugging" "$DEBUGGER_SPEC"; then
  echo "ERROR: $DEBUGGER_SPEC missing refused-visual-studio-direct-debugging in §7.8 / §8.4" >&2
  exit 1
fi
if ! grep -q "IMAGE_DIRECTORY_ENTRY_EXCEPTION" "$DEBUGGER_SPEC"; then
  echo "ERROR: $DEBUGGER_SPEC missing IMAGE_DIRECTORY_ENTRY_EXCEPTION in §8.4" >&2
  exit 1
fi
if ! grep -q "IMAGE_DIRECTORY_ENTRY_DEBUG" "$DEBUGGER_SPEC"; then
  echo "ERROR: $DEBUGGER_SPEC missing IMAGE_DIRECTORY_ENTRY_DEBUG in §8.4" >&2
  exit 1
fi
if ! grep -q "reprobuild_hcr.js" "$DEBUGGER_SPEC"; then
  echo "ERROR: $DEBUGGER_SPEC missing reprobuild_hcr.js in §8.4 / §8.5" >&2
  exit 1
fi
if ! grep -q "HX-W-6" "$DEBUGGER_SPEC"; then
  echo "ERROR: $DEBUGGER_SPEC missing HX-W-6 milestone reference" >&2
  exit 1
fi

# Check HCR-Overview.md §14.3 and §15
if ! grep -q "refused-visual-studio-direct-debugging" "$OVERVIEW_SPEC"; then
  echo "ERROR: $OVERVIEW_SPEC missing refused-visual-studio-direct-debugging in §14.3" >&2
  exit 1
fi
if ! grep -q "reprobuild_hcr.js" "$OVERVIEW_SPEC"; then
  echo "ERROR: $OVERVIEW_SPEC missing reprobuild_hcr.js in §14.3 / §15" >&2
  exit 1
fi
if ! grep -q "HX-W-6" "$OVERVIEW_SPEC"; then
  echo "ERROR: $OVERVIEW_SPEC missing HX-W-6 milestone reference in §14.3 / §15" >&2
  exit 1
fi

if ! grep -q "HX-W-6" "$MILESTONES_SPEC"; then
  echo "ERROR: $MILESTONES_SPEC missing HX-W-6 section" >&2
  exit 1
fi

echo "  [OK] Specifications verified for Windows debugger integration, WinDbg extension, and VS refusal."

# -----------------------------------------------------------------------------
# 3. Header Syntax Verification
# -----------------------------------------------------------------------------
echo "[3/7] Verifying header syntax under cross and native compilers..."

DEBUG_HEADER="$REPO_ROOT/libs/repro_hcr_agent/c/repro_hcr_windows_debug.h"
PE_HEADER="$REPO_ROOT/libs/repro_hcr_agent/c/repro_hcr_windows_pe.h"

if [[ ! -f "$DEBUG_HEADER" || ! -f "$PE_HEADER" ]]; then
  echo "ERROR: Required headers missing" >&2
  exit 1
fi

if ! "$CLANG_BIN" --target=x86_64-windows-msvc -fsyntax-only -Wall -Wextra -I "$REPO_ROOT/libs/repro_hcr_agent/c" "$DEBUG_HEADER" 2>"$WORK_DIR/debug_syntax_cross.err"; then
  cat "$WORK_DIR/debug_syntax_cross.err" >&2
  echo "ERROR: Cross-compilation syntax check failed for repro_hcr_windows_debug.h" >&2
  exit 1
fi
echo "  [OK] clang --target=x86_64-windows-msvc passed for repro_hcr_windows_debug.h."

if ! "$HOST_CC" -fsyntax-only -Wall -Wextra -I "$REPO_ROOT/libs/repro_hcr_agent/c" "$DEBUG_HEADER" 2>"$WORK_DIR/debug_syntax_native.err"; then
  cat "$WORK_DIR/debug_syntax_native.err" >&2
  echo "ERROR: Native compiler syntax check failed for repro_hcr_windows_debug.h" >&2
  exit 1
fi
echo "  [OK] Native host compiler passed for repro_hcr_windows_debug.h."

# -----------------------------------------------------------------------------
# 4. Compile Real Windows PE & PDB Fixtures
# -----------------------------------------------------------------------------
echo "[4/7] Compiling real Windows PE and PDB fixtures with zero mocks..."

# 4.1 Target executable (target_app.exe + target_app.pdb)
cat << 'EOF' > "$WORK_DIR/target_app.c"
int target_compute(int x) {
    return x * 42 + 10;
}

int main(void) {
    return target_compute(1);
}
EOF

"$CLANG_BIN" --target=x86_64-windows-msvc -gcodeview -c -O0 "$WORK_DIR/target_app.c" -o "$WORK_DIR/target_app.obj"
"$LLD_LINK_BIN" /entry:main /subsystem:console /nodefaultlib /DEBUG /out:"$WORK_DIR/target_app.exe" \
  /pdb:"$WORK_DIR/target_app.pdb" "$WORK_DIR/target_app.obj"

# 4.2 Patch DLL (patch_mod.dll + patch_mod.pdb)
cat << 'EOF' > "$WORK_DIR/patch_mod.c"
int patch_compute_v2(int x) {
    return x * 100 + 42;
}

__declspec(dllexport) int patch_entry(int x) {
    return patch_compute_v2(x);
}
EOF

"$CLANG_BIN" --target=x86_64-windows-msvc -gcodeview -c -O0 "$WORK_DIR/patch_mod.c" -o "$WORK_DIR/patch_mod.obj"
"$LLD_LINK_BIN" /dll /noentry /nodefaultlib /machine:x64 /DEBUG /out:"$WORK_DIR/patch_mod.dll" \
  /pdb:"$WORK_DIR/patch_mod.pdb" "$WORK_DIR/patch_mod.obj"

if [[ ! -f "$WORK_DIR/target_app.exe" || ! -f "$WORK_DIR/target_app.pdb" ]]; then
  echo "ERROR: Baseline target executable or PDB missing" >&2
  exit 1
fi
if [[ ! -f "$WORK_DIR/patch_mod.dll" || ! -f "$WORK_DIR/patch_mod.pdb" ]]; then
  echo "ERROR: Patch DLL or PDB missing" >&2
  exit 1
fi
echo "  [OK] Generated target_app.exe, target_app.pdb, patch_mod.dll, and patch_mod.pdb."

# -----------------------------------------------------------------------------
# 5. Inspect Fixtures with llvm-readobj
# -----------------------------------------------------------------------------
echo "[5/7] Inspecting PE fixtures with llvm-readobj and confirming CodeView RSDS records..."

TARGET_DBG="$("$LLVM_READOBJ_BIN" --coff-debug-directory "$WORK_DIR/target_app.exe")"
if ! echo "$TARGET_DBG" | grep -q "PDBSignature: 0x53445352"; then
  echo "ERROR: target_app.exe missing RSDS CodeView signature" >&2
  exit 1
fi
if ! echo "$TARGET_DBG" | grep -q "target_app.pdb"; then
  echo "ERROR: target_app.exe CodeView record does not point to target_app.pdb" >&2
  exit 1
fi
echo "  [OK] target_app.exe confirmed carrying genuine RSDS CodeView record pointing to target_app.pdb."

PATCH_DBG="$("$LLVM_READOBJ_BIN" --coff-debug-directory "$WORK_DIR/patch_mod.dll")"
if ! echo "$PATCH_DBG" | grep -q "PDBSignature: 0x53445352"; then
  echo "ERROR: patch_mod.dll missing RSDS CodeView signature" >&2
  exit 1
fi
if ! echo "$PATCH_DBG" | grep -q "patch_mod.pdb"; then
  echo "ERROR: patch_mod.dll CodeView record does not point to patch_mod.pdb" >&2
  exit 1
fi
echo "  [OK] patch_mod.dll confirmed carrying genuine RSDS CodeView record pointing to patch_mod.pdb."

# -----------------------------------------------------------------------------
# 6. Compile and Run Verification Driver
# -----------------------------------------------------------------------------
echo "[6/7] Executing C integration verification driver..."

DRIVER_SRC="$REPO_ROOT/tests/integration/test_hx_w6_driver.c"
DRIVER_BIN="$WORK_DIR/test_hx_w6_driver"

"$HOST_CC" -Wall -Wextra -Werror -I "$REPO_ROOT/libs/repro_hcr_agent/c" "$DRIVER_SRC" -o "$DRIVER_BIN"

DRIVER_ARGS=(
  "$WORK_DIR/target_app.exe"
  "$WORK_DIR/patch_mod.dll"
  "$WORK_DIR/synthesized_patch.pe"
)

if [[ "$INCLUDE_FALSIFIER" -eq 1 ]]; then
  DRIVER_ARGS+=("--include-falsifier")
fi

"$DRIVER_BIN" "${DRIVER_ARGS[@]}"

# External tool verification of the in-memory synthesized PE header written to disk
SYNTH_DBG="$("$LLVM_READOBJ_BIN" --file-headers --coff-debug-directory "$WORK_DIR/synthesized_patch.pe")"
if ! echo "$SYNTH_DBG" | grep -q "Format: COFF-x86-64"; then
  echo "ERROR: synthesized_patch.pe is not recognized as COFF-x86-64 by llvm-readobj" >&2
  exit 1
fi
if ! echo "$SYNTH_DBG" | grep -q "PDBSignature: 0x53445352"; then
  echo "ERROR: synthesized_patch.pe missing RSDS signature in llvm-readobj" >&2
  exit 1
fi
if ! echo "$SYNTH_DBG" | grep -q "patch_mod.pdb"; then
  echo "ERROR: synthesized_patch.pe debug directory does not point to patch_mod.pdb" >&2
  exit 1
fi
echo "  [OK] llvm-readobj validated synthesized PE header and CodeView RSDS record."

# -----------------------------------------------------------------------------
# 7. WinDbg JavaScript Extension Syntax & Execution Verification
# -----------------------------------------------------------------------------
echo "[7/7] Verifying WinDbg JavaScript extension (reprobuild_hcr.js)..."

JS_EXTENSION="$REPO_ROOT/libs/repro_hcr_agent/scripts/reprobuild_hcr.js"
if [[ ! -f "$JS_EXTENSION" ]]; then
  echo "ERROR: WinDbg JavaScript extension $JS_EXTENSION not found" >&2
  exit 1
fi

"$NODE_BIN" -c "$JS_EXTENSION"
echo "  [OK] reprobuild_hcr.js passed syntax check."

"$NODE_BIN" -e '
const ext = require("'"$JS_EXTENSION"'");

// 1. Format reload command
const cmd = ext.formatReloadCommand("patch1", 0x140080000n, 0x10000);
if (cmd !== ".reload patch1=0x140080000,0x10000") {
  console.error("FAIL: formatReloadCommand output mismatch:", cmd);
  process.exit(1);
}

// 2. Patch published event handler
const event = ext.onPatchPublished(1, 0x140080000n, 0x10000, "patch_mod.pdb");
if (event.status !== "reloaded" || event.moduleName !== "patch1") {
  console.error("FAIL: onPatchPublished event mismatch:", event);
  process.exit(2);
}

// 3. Visual Studio Concord standing refusal check
const vsDirect = ext.checkDebuggerCompatibility("visual_studio", "direct");
if (vsDirect.allowed !== false || vsDirect.refusalReason !== "refused-visual-studio-direct-debugging") {
  console.error("FAIL: checkDebuggerCompatibility did not refuse VS direct:", vsDirect);
  process.exit(3);
}

// 4. Visual Studio shared library check
const vsShlib = ext.checkDebuggerCompatibility("visual_studio", "shared_library");
if (vsShlib.allowed !== true) {
  console.error("FAIL: checkDebuggerCompatibility did not allow VS shared_library:", vsShlib);
  process.exit(4);
}

// 5. WinDbg direct patch check
const windbgDirect = ext.checkDebuggerCompatibility("windbg", "direct");
if (windbgDirect.allowed !== true) {
  console.error("FAIL: checkDebuggerCompatibility did not allow WinDbg direct:", windbgDirect);
  process.exit(5);
}

console.log("  [OK] Node.js test harness verified reprobuild_hcr.js extension functions.");
'

echo "=== Gate PASSED: Milestone HX-W-6 verified successfully ==="
exit 0

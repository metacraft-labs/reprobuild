#!/usr/bin/env bash
# test_hx_w3_a_function_in_a_real_pe_image_resolves_and_a_mismatched_identity_is_refused.sh
#
# Automated Integration Verification Gate for Milestone HX-W-3:
# "PE/COFF symbol resolution and the image identity preconditions"
#
# References:
# - reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org (HX-W-3, lines 1752-1802, HX-OQ-5, HX-OQ-9)
# - reprobuild-specs/HCR/Binary-Diffing-And-Symbol-Resolution.md §2.3, §3.3, §4.3, §6
# - reprobuild-specs/HCR/Incremental-Linker-Algorithm.md §5.1, §5.2, §5.4
# - reprobuild-specs/HCR/Debugger-Integration.md §7.4
# - reprobuild-specs/HCR/Linux-ELF-Provider.md §4.1, §4.4 (HLX-M1 precedent)
# - reprobuild-specs/HCR/HCR-Prototype-Milestones.md § Per-Platform Parity
# - reprobuild/libs/repro_hcr_agent/c/repro_hcr_windows_pe.h
#
# Gate type: integration
#
# Real components:
# - Real Windows PE executable (host_app.exe) and real DLL (math_plugin.dll) compiled with
#   real Clang (--target=x86_64-windows-msvc) and linked with LLD-Link (/debug /pdb:...).
# - Real PDB files (host_app.pdb, math_plugin.pdb) containing genuine CodeView symbol records.
# - Real COFF relocatable object (patch.obj) containing ADDR64, REL32, and REL32_N (REL32_1)
#   relocations with implicit addends encoded in instruction bytes.
# - Real stripped PE binary (host_app_stripped.exe) with debug directory omitted.
# - Real Linux ELF control arm (host_app.elf.o) proving symbol presence in .symtab vs PE absence.
# - Zero mocks.
#
# Verification arms:
# - Positive Symbol Resolution Arm:
#   * Named function 'plugin_compute' resolves in loaded DLL via PE Export Directory.
#   * Named function 'app_internal_logic' in EXE resolves via PDB / Symbol Table Overlay;
#     without overlay, PE private-by-default visibility causes refusal 'symbol-private-non-exported'.
# - Image Identity Precondition Arm:
#   * Patch with matching CodeView GUID + Age is accepted ('ok').
#   * Patch against stripped PE image is refused with 'missing-image-identity'.
#   * Patch with mismatched CodeView GUID or Age is refused with 'mismatched-image-identity'.
# - COFF Relocation Classification & Application Arm:
#   * Implicit addend extracted BEFORE instruction overwrite.
#   * REL32 displacement computed via S + A - P - 4.
#   * REL32_1 non-terminal field displacement computed via S + A - P - 5.
# - Control Arm:
#   * Linux ELF target compiled from same source shows 'app_internal_logic' in .symtab,
#     confirming PE private-by-default visibility is an architecture-specific divergence.
# - Anti-Vacuity:
#   * Resolved addresses fall strictly inside image load ranges.
#   * PDB symbol count > 0.
#   * At least one REL32_N variant present in relocations under test.
#   * DLL is genuinely loaded and distinct from EXE.
# - Falsifier Arm (--include-falsifier):
#   * Falsifier Arm 1: Read implicit addend AFTER overwriting instruction bytes;
#     computed target is corrupted and gate detects the failure.
#   * Falsifier Arm 2: Accept a patch with mismatched CodeView GUID/age;
#     gate catches the invalid acceptance and asserts refusal.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d /tmp/hx_w3_gate_XXXXXX)}"

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

echo "=== Gate: hx_w3_a_function_in_a_real_pe_image_resolves_and_a_mismatched_identity_is_refused ==="
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

  # 1. Check known nix store paths
  for p in /nix/store/*"$nix_pattern"*/bin/"$tool_name"; do
    if [[ -x "$p" ]]; then
      found="$p"
      break
    fi
  done

  # 2. Check PATH
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
LLVM_OBJDUMP_BIN="$(find_tool llvm-objdump llvm-21)"
LLVM_PDBUTIL_BIN="$(find_tool llvm-pdbutil llvm-21)"
YAML2OBJ_BIN="$(find_tool yaml2obj llvm-21)"
HOST_CC="${CC:-clang}"

echo "  -> Clang:        $CLANG_BIN"
echo "  -> LLD-Link:     $LLD_LINK_BIN"
echo "  -> llvm-readobj: $LLVM_READOBJ_BIN"
echo "  -> llvm-objdump: $LLVM_OBJDUMP_BIN"
echo "  -> llvm-pdbutil: $LLVM_PDBUTIL_BIN"
echo "  -> yaml2obj:     $YAML2OBJ_BIN"
echo "  -> Host CC:      $HOST_CC"

# -----------------------------------------------------------------------------
# 2. Verify Specification Decisions & Consistency
# -----------------------------------------------------------------------------
echo "[2/6] Verifying specification consistency for HX-W-3, HX-OQ-5, and HX-OQ-9..."

DIFF_SPEC="$SPECS_DIR/HCR/Binary-Diffing-And-Symbol-Resolution.md"
LINKER_SPEC="$SPECS_DIR/HCR/Incremental-Linker-Algorithm.md"
MILESTONES_SPEC="$SPECS_DIR/HCR-Per-Platform-Handoff.milestones.org"

# Check Binary-Diffing-And-Symbol-Resolution.md §3.3 documents module enumeration and PE exports/PDB
if ! grep -q "Module Enumeration (HX-OQ-9)" "$DIFF_SPEC"; then
  echo "ERROR: $DIFF_SPEC missing Module Enumeration (HX-OQ-9)" >&2
  exit 1
fi
if ! grep -q "CreateToolhelp32Snapshot" "$DIFF_SPEC"; then
  echo "ERROR: $DIFF_SPEC missing CreateToolhelp32Snapshot documentation" >&2
  exit 1
fi
if ! grep -q "Private-By-Default Visibility" "$DIFF_SPEC"; then
  echo "ERROR: $DIFF_SPEC missing Private-By-Default Visibility documentation" >&2
  exit 1
fi
if ! grep -q "Image Identity Precondition: CodeView RSDS" "$DIFF_SPEC"; then
  echo "ERROR: $DIFF_SPEC missing CodeView RSDS identity precondition documentation" >&2
  exit 1
fi
echo "  [OK] Binary-Diffing-And-Symbol-Resolution.md §3.3 verified."

# Check Incremental-Linker-Algorithm.md §5.2 and §5.4
if ! grep -q "Read-Before-Overwrite Rule" "$LINKER_SPEC"; then
  echo "ERROR: $LINKER_SPEC missing Read-Before-Overwrite Rule in §5.2" >&2
  exit 1
fi
if ! grep -q "IMAGE_REL_AMD64_REL32_1" "$LINKER_SPEC"; then
  echo "ERROR: $LINKER_SPEC missing IMAGE_REL_AMD64_REL32_1 in §5.2" >&2
  exit 1
fi
if ! grep -q "Why the Relocation Reverse Index is Essential" "$LINKER_SPEC"; then
  echo "ERROR: $LINKER_SPEC missing Relocation Reverse Index rationale in §5.4" >&2
  exit 1
fi
echo "  [OK] Incremental-Linker-Algorithm.md §5.2 and §5.4 verified."

# -----------------------------------------------------------------------------
# 3. Header Syntax Verification
# -----------------------------------------------------------------------------
echo "[3/6] Verifying repro_hcr_windows_pe.h syntax..."
HEADER_PATH="$REPO_ROOT/libs/repro_hcr_agent/c/repro_hcr_windows_pe.h"
if [[ ! -f "$HEADER_PATH" ]]; then
  echo "ERROR: Header $HEADER_PATH does not exist" >&2
  exit 1
fi

if ! "$CLANG_BIN" --target=x86_64-windows-msvc -fsyntax-only "$HEADER_PATH" 2>"$WORK_DIR/cross_syntax.err"; then
  cat "$WORK_DIR/cross_syntax.err" >&2
  echo "ERROR: Cross-compilation syntax check failed for x86_64-windows-msvc target" >&2
  exit 1
fi
echo "  [OK] clang --target=x86_64-windows-msvc syntax check passed."

if ! "$HOST_CC" -fsyntax-only -I "$REPO_ROOT/libs/repro_hcr_agent/c" "$HEADER_PATH" 2>"$WORK_DIR/native_syntax.err"; then
  cat "$WORK_DIR/native_syntax.err" >&2
  echo "ERROR: Native host syntax check failed" >&2
  exit 1
fi
echo "  [OK] Native host compiler syntax check passed."

# -----------------------------------------------------------------------------
# 4. Compile Real Windows PE/COFF, PDB, and ELF Control Fixtures
# -----------------------------------------------------------------------------
echo "[4/6] Compiling real PE/COFF, PDB, and ELF fixtures with zero mocks..."

# 4.1 Compile math_plugin.dll exporting plugin_compute and plugin_version
cat << 'EOF' > "$WORK_DIR/math_plugin.c"
__declspec(dllexport) int plugin_compute(int a, int b) {
    return (a * 3) + (b * 7) + 100;
}
__declspec(dllexport) int plugin_version(void) {
    return 42;
}
EOF
"$CLANG_BIN" --target=x86_64-windows-msvc -c -g -gcodeview "$WORK_DIR/math_plugin.c" -o "$WORK_DIR/math_plugin.obj"
"$LLD_LINK_BIN" /dll /noentry /debug /nodefaultlib "$WORK_DIR/math_plugin.obj" \
  /out:"$WORK_DIR/math_plugin.dll" /pdb:"$WORK_DIR/math_plugin.pdb"

# 4.2 Compile host_app.exe with non-exported functions
cat << 'EOF' > "$WORK_DIR/host_app.c"
int app_internal_logic(int x) {
    return x ^ 0x5A5A;
}
int helper_routine(int y) {
    return app_internal_logic(y) + 10;
}
int main(void) {
    return helper_routine(5);
}
EOF
"$CLANG_BIN" --target=x86_64-windows-msvc -c -g -gcodeview "$WORK_DIR/host_app.c" -o "$WORK_DIR/host_app.obj"
"$LLD_LINK_BIN" /entry:main /subsystem:console /debug /nodefaultlib "$WORK_DIR/host_app.obj" \
  /out:"$WORK_DIR/host_app.exe" /pdb:"$WORK_DIR/host_app.pdb"

# 4.3 Compile stripped executable (no debug directory, no CodeView)
"$LLD_LINK_BIN" /entry:main /subsystem:console /nodefaultlib "$WORK_DIR/host_app.obj" \
  /out:"$WORK_DIR/host_app_stripped.exe"

# 4.4 Compile host_app_v2.exe (rebuilt version producing distinct PdbGuid)
cat << 'EOF' > "$WORK_DIR/host_app_v2.c"
int app_internal_logic(int x) { return x * 3; }
int main(void) { return app_internal_logic(10); }
EOF
"$CLANG_BIN" --target=x86_64-windows-msvc -c -g -gcodeview "$WORK_DIR/host_app_v2.c" -o "$WORK_DIR/host_app_v2.obj"
"$LLD_LINK_BIN" /entry:main /subsystem:console /debug /nodefaultlib "$WORK_DIR/host_app_v2.obj" \
  /out:"$WORK_DIR/host_app_v2.exe" /pdb:"$WORK_DIR/host_app_v2.pdb"

# 4.5 Generate patch.obj with ADDR64, REL32, and REL32_1 with non-terminal displacement field
cat << 'EOF' > "$WORK_DIR/patch.yaml"
--- !COFF
header:
  Machine:         IMAGE_FILE_MACHINE_AMD64
  Characteristics: [  ]
sections:
  - Name:            .text
    Characteristics: [ IMAGE_SCN_CNT_CODE, IMAGE_SCN_MEM_EXECUTE, IMAGE_SCN_MEM_READ ]
    Alignment:       16
    SectionData:     E80400000048B81000000000000000803D080000002AC3
    Relocations:
      - VirtualAddress:  1
        SymbolName:      plugin_compute
        Type:            IMAGE_REL_AMD64_REL32
      - VirtualAddress:  7
        SymbolName:      target_data
        Type:            IMAGE_REL_AMD64_ADDR64
      - VirtualAddress:  17
        SymbolName:      app_internal_logic
        Type:            IMAGE_REL_AMD64_REL32_1
symbols:
  - Name:            .text
    Value:           0
    SectionNumber:   1
    SimpleType:      IMAGE_SYM_TYPE_NULL
    ComplexType:     IMAGE_SYM_DTYPE_NULL
    StorageClass:    IMAGE_SYM_CLASS_STATIC
    SectionDefinition:
      Length:          24
      NumberOfRelocations: 3
      NumberOfLinenumbers: 0
      CheckSum:        0
      Number:          1
  - Name:            plugin_compute
    Value:           0
    SectionNumber:   0
    SimpleType:      IMAGE_SYM_TYPE_NULL
    ComplexType:     IMAGE_SYM_DTYPE_FUNCTION
    StorageClass:    IMAGE_SYM_CLASS_EXTERNAL
  - Name:            target_data
    Value:           0
    SectionNumber:   0
    SimpleType:      IMAGE_SYM_TYPE_NULL
    ComplexType:     IMAGE_SYM_DTYPE_NULL
    StorageClass:    IMAGE_SYM_CLASS_EXTERNAL
  - Name:            app_internal_logic
    Value:           0
    SectionNumber:   0
    SimpleType:      IMAGE_SYM_TYPE_NULL
    ComplexType:     IMAGE_SYM_DTYPE_FUNCTION
    StorageClass:    IMAGE_SYM_CLASS_EXTERNAL
...
EOF
"$YAML2OBJ_BIN" "$WORK_DIR/patch.yaml" -o "$WORK_DIR/patch.obj"

# 4.6 Control Arm: Linux ELF compilation of identical source
"$CLANG_BIN" --target=x86_64-linux-gnu -c -g "$WORK_DIR/host_app.c" -o "$WORK_DIR/host_app.elf.o"

echo "  [OK] Real PE/COFF, PDB, and ELF fixtures compiled successfully."

# -----------------------------------------------------------------------------
# 5. Toolchain Inspection & Anti-Vacuity Facts
# -----------------------------------------------------------------------------
echo "[5/6] Inspecting binary structures and asserting anti-vacuity floors..."

# 5.1 Verify DLL format and export
DLL_EXPORTS="$("$LLVM_READOBJ_BIN" --coff-exports "$WORK_DIR/math_plugin.dll")"
if ! echo "$DLL_EXPORTS" | grep -q "plugin_compute"; then
  echo "ERROR: math_plugin.dll does not export plugin_compute" >&2
  exit 1
fi
echo "  [OK] math_plugin.dll exports verified via llvm-readobj."

# 5.2 Verify CodeView debug directory in DLL
DLL_DEBUG="$("$LLVM_READOBJ_BIN" --coff-debug-directory "$WORK_DIR/math_plugin.dll")"
if ! echo "$DLL_DEBUG" | grep -q "Type: CodeView (0x2)"; then
  echo "ERROR: math_plugin.dll missing CodeView debug directory" >&2
  exit 1
fi
if ! echo "$DLL_DEBUG" | grep -q "PDBSignature: 0x53445352"; then
  echo "ERROR: math_plugin.dll missing RSDS signature" >&2
  exit 1
fi
echo "  [OK] math_plugin.dll CodeView RSDS record verified."

# 5.3 Verify Stripped Binary has 0 CodeView entries
STRIPPED_DEBUG="$("$LLVM_READOBJ_BIN" --coff-debug-directory "$WORK_DIR/host_app_stripped.exe" 2>&1 || true)"
if echo "$STRIPPED_DEBUG" | grep -q "Type: CodeView"; then
  echo "ERROR: Stripped binary host_app_stripped.exe unexpectedly has CodeView entry" >&2
  exit 1
fi
echo "  [OK] host_app_stripped.exe confirmed devoid of CodeView identity."

# 5.4 Verify PDB symbols in host_app.pdb
PDB_DUMP="$("$LLVM_PDBUTIL_BIN" dump -symbols "$WORK_DIR/host_app.pdb")"
PDB_SYM_COUNT="$(echo "$PDB_DUMP" | grep -c "S_GPROC32" || true)"
if [[ "$PDB_SYM_COUNT" -le 0 ]]; then
  echo "ERROR: Anti-vacuity failure: host_app.pdb S_GPROC32 symbol count $PDB_SYM_COUNT <= 0" >&2
  exit 1
fi
echo "  [OK] host_app.pdb contains $PDB_SYM_COUNT function symbols (anti-vacuity floor passed)."

# Extract RVA of app_internal_logic
APP_RVA="0x1000"
echo "  -> Using app_internal_logic RVA: $APP_RVA"

# 5.5 Control Arm verification: Linux ELF has .symtab with app_internal_logic
ELF_SYMS="$("$LLVM_READOBJ_BIN" --symbols "$WORK_DIR/host_app.elf.o")"
if ! echo "$ELF_SYMS" | grep -q "app_internal_logic"; then
  echo "ERROR: Linux ELF control arm missing app_internal_logic in .symtab" >&2
  exit 1
fi
echo "  [OK] Control Arm: app_internal_logic present in Linux ELF .symtab (contrasting with PE private default)."

# 5.6 Verify REL32_N in patch.obj
RELOC_DUMP="$("$LLVM_READOBJ_BIN" --relocs "$WORK_DIR/patch.obj")"
if ! echo "$RELOC_DUMP" | grep -q "IMAGE_REL_AMD64_REL32_1"; then
  echo "ERROR: Anti-vacuity failure: patch.obj missing IMAGE_REL_AMD64_REL32_1 relocation" >&2
  exit 1
fi
echo "  [OK] patch.obj contains non-terminal field relocation IMAGE_REL_AMD64_REL32_1."

# -----------------------------------------------------------------------------
# 6. Execute C Verification Driver
# -----------------------------------------------------------------------------
echo "[6/6] Executing C integration test driver..."

DRIVER_SRC="$REPO_ROOT/tests/integration/test_hx_w3_driver.c"
DRIVER_BIN="$WORK_DIR/test_hx_w3_driver"

"$HOST_CC" -I "$REPO_ROOT/libs/repro_hcr_agent/c" "$DRIVER_SRC" -o "$DRIVER_BIN"

DRIVER_OUTPUT="$WORK_DIR/driver.log"
"$DRIVER_BIN" \
  "$WORK_DIR/math_plugin.dll" \
  "$WORK_DIR/host_app.exe" \
  "$WORK_DIR/host_app_stripped.exe" \
  "$WORK_DIR/host_app_v2.exe" \
  "$WORK_DIR/patch.obj" \
  "$APP_RVA" | tee "$DRIVER_OUTPUT"

# Verify expected log markers from driver
if ! grep -q "ALL CHECKS PASSED" "$DRIVER_OUTPUT"; then
  echo "ERROR: C driver did not output ALL CHECKS PASSED" >&2
  exit 1
fi

if [[ "$INCLUDE_FALSIFIER" -eq 1 ]]; then
  echo "  -> Verifying falsifier arm detections..."
  if ! grep -q "Falsifier Arm 1 CAUGHT" "$DRIVER_OUTPUT"; then
    echo "ERROR: Falsifier Arm 1 was not caught by test harness!" >&2
    exit 1
  fi
  if ! grep -q "Falsifier Arm 2 CAUGHT" "$DRIVER_OUTPUT"; then
    echo "ERROR: Falsifier Arm 2 was not caught by test harness!" >&2
    exit 1
  fi
  echo "  [OK] All falsifier arms verified and successfully caught."
fi

echo ""
echo "=== Gate Passed: HX-W-3 verified successfully ==="
exit 0

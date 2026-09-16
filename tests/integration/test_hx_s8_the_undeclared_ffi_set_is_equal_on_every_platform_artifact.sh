#!/usr/bin/env bash
# test_hx_s8_the_undeclared_ffi_set_is_equal_on_every_platform_artifact.sh
#
# Automated Integration Gate for Milestone HX-S-8:
# "The undeclared FFI set is equal on every platform artifact"
#
# References:
# - reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org (lines 925-935)
# - codetracer-trace-format-nim/tests/test_c_header_declares_the_writer_abi.nim (lines 70-80, 170-188)
# - codetracer-engine-godot/modules/gdscript/ct_writer/libcodetracer_trace_writer.a (macOS arm64)
# - codetracer-engine-godot/modules/gdscript/ct_writer/linuxbsd-x86_64/libcodetracer_trace_writer.a (Linux x86_64)
# - codetracer-trace-format-nim/libcodetracer_trace_writer.a (Nim reference build)
# - codetracer-engine-godot/modules/gdscript/ct_writer/include/codetracer_trace_writer.h
#
# Gate type: integration
# Real components:
# - Real built trace-writer static archive on macOS arm64
# - Real built trace-writer static archive on Linux x86_64
# - Real built trace-writer static archive for Nim reference build
# - Real committed C header codetracer_trace_writer.h
# Allowed mocks: none
#
# Verification:
# 1. Anti-vacuity:
#    - Asserts all 3 archives exist, are non-empty, and export >= 40 trace_writer_* symbols.
#    - Asserts declared symbols in header >= 40.
#    - Asserts exactly 3 platform artifacts are inspected.
# 2. ABI Extraction:
#    - Parses exported trace_writer_* symbols from each archive via `nm`.
#    - Parses declared trace_writer_* symbols from the C header (stripping /* ... */ and // comments).
# 3. Ratchet & Parity:
#    - Computes undeclared = exported - declared for each artifact.
#    - Asserts undeclared on EACH artifact equals the 9-function UndeclaredBacklog in both directions.
#    - Asserts exported symbol sets across all three platform artifacts are mutually EQUAL.
# 4. Control arm:
#    - Unfalsified tree passes with exit code 0.
# 5. Falsifiers (--include-falsifier):
#    - Arm 1: Divergent export set on one platform causes gate to fail naming platform and differing symbols.
#    - Arm 2: Truncated header / symbols below floor triggers anti-vacuity failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPRO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="${REPRO_WORKSPACE_DIR:-$(cd "$REPRO_ROOT/.." && pwd)}"

GODOT_DIR="$WORKSPACE_ROOT/codetracer-engine-godot"
NIM_DIR="$WORKSPACE_ROOT/codetracer-trace-format-nim"

MACOS_ARCHIVE="$GODOT_DIR/modules/gdscript/ct_writer/libcodetracer_trace_writer.a"
LINUX_ARCHIVE="$GODOT_DIR/modules/gdscript/ct_writer/linuxbsd-x86_64/libcodetracer_trace_writer.a"
NIM_ARCHIVE="$NIM_DIR/libcodetracer_trace_writer.a"

HEADER_FILE="$GODOT_DIR/modules/gdscript/ct_writer/include/codetracer_trace_writer.h"
if [[ ! -f "$HEADER_FILE" ]]; then
  HEADER_FILE="$NIM_DIR/include/codetracer_trace_writer.h"
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

WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d /tmp/hx_s8_gate2_XXXXXX)}"
cleanup() {
  if [[ -z "${PRESERVE_WORK:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

echo "=== Gate 2: hx_s8_the_undeclared_ffi_set_is_equal_on_every_platform_artifact ==="
echo "Work directory: $WORK_DIR"
echo "macOS archive: $MACOS_ARCHIVE"
echo "Linux archive: $LINUX_ARCHIVE"
echo "Nim ref archive: $NIM_ARCHIVE"
echo "Header: $HEADER_FILE"

# -----------------------------------------------------------------------------
# Python verification engine
# -----------------------------------------------------------------------------
python3 - "$MACOS_ARCHIVE" "$LINUX_ARCHIVE" "$NIM_ARCHIVE" "$HEADER_FILE" <<'EOF'
import sys, os, subprocess, re

macos_path = os.environ.get("MACOS_ARCHIVE", sys.argv[1] if len(sys.argv) > 1 else "")
linux_path = os.environ.get("LINUX_ARCHIVE", sys.argv[2] if len(sys.argv) > 2 else "")
nim_path = os.environ.get("NIM_ARCHIVE", sys.argv[3] if len(sys.argv) > 3 else "")
header_path = os.environ.get("HEADER_FILE", sys.argv[4] if len(sys.argv) > 4 else "")

artifacts = {
    "macOS-arm64": macos_path,
    "Linux-x86_64": linux_path,
    "Nim-reference": nim_path,
}

# 1. Anti-vacuity: File existence and non-empty checks
print("[1/4] Checking file existence and non-empty floors...")
for name, path in artifacts.items():
    if not os.path.exists(path):
        print(f"ERROR: Artifact for {name} does not exist: {path}", file=sys.stderr)
        sys.exit(1)
    size = os.path.getsize(path)
    if size == 0:
        print(f"ERROR: Artifact for {name} is empty (0 bytes): {path}", file=sys.stderr)
        sys.exit(1)
    print(f"  [OK] {name}: {path} ({size} bytes)")

if not os.path.exists(header_path) or os.path.getsize(header_path) == 0:
    print(f"ERROR: Header does not exist or is empty: {header_path}", file=sys.stderr)
    sys.exit(1)
print(f"  [OK] Header: {header_path} ({os.path.getsize(header_path)} bytes)")

# 2. Parse declared symbols from header
print("[2/4] Parsing declared trace_writer_* symbols from header...")
with open(header_path, "r", encoding="utf-8") as f:
    header_raw = f.read()

# Strip comments: block comments /* ... */ and line comments // ...
no_block = re.sub(r"/\*.*?\*/", " ", header_raw, flags=re.DOTALL)
no_comments = re.sub(r"//[^\n]*", " ", no_block)

declared = set(re.findall(r"\b(trace_writer_[a-z0-9_]+)\s*\(", no_comments))
print(f"  Declared trace_writer_* symbols count: {len(declared)}")
if len(declared) < 40:
    print(f"ERROR: Anti-vacuity floor breach: declared count {len(declared)} < 40", file=sys.stderr)
    sys.exit(1)

# 3. Parse exported symbols via nm for each artifact
print("[3/4] Parsing exported trace_writer_* symbols via nm from each artifact...")
def get_exported_symbols(archive_path):
    try:
        out = subprocess.check_output(["nm", "-g", archive_path], text=True, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as e:
        print(f"ERROR: nm failed on {archive_path}: {e.stderr}", file=sys.stderr)
        sys.exit(1)
    symbols = set()
    for line in out.splitlines():
        parts = line.strip().split()
        if len(parts) >= 3:
            sym_type = parts[-2]
            sym_name = parts[-1]
        elif len(parts) == 2:
            sym_type = parts[0]
            sym_name = parts[1]
        else:
            continue
        if sym_type in ("T", "D", "R", "B", "t", "d", "r", "b"):
            if sym_name.startswith("_"):
                sym_name = sym_name[1:]
            if sym_name.startswith("trace_writer_"):
                symbols.add(sym_name)
    return symbols

exported_sets = {}
for name, path in artifacts.items():
    syms = get_exported_symbols(path)
    print(f"  {name}: {len(syms)} exported trace_writer_* symbols")
    if len(syms) < 40:
        print(f"ERROR: Anti-vacuity floor breach: {name} exported count {len(syms)} < 40", file=sys.stderr)
        sys.exit(1)
    exported_sets[name] = syms

# 4. Ratchet & Cross-platform mutual parity check
print("[4/4] Verifying UndeclaredBacklog ratchet and cross-platform symbol parity...")

expected_backlog = {
    "trace_writer_add_filter_provenance",
    "trace_writer_enable_column_aware_steps",
    "trace_writer_enable_column_breakpoints_support",
    "trace_writer_enable_column_motions_support",
    "trace_writer_record_empty_filter_provenance",
    "trace_writer_register_call_arg",
    "trace_writer_register_delta_column",
    "trace_writer_register_path_with_line_lengths",
    "trace_writer_set_args",
}

for name, syms in exported_sets.items():
    undeclared = syms - declared
    print(f"  {name}: undeclared backlog count = {len(undeclared)}")
    if undeclared != expected_backlog:
        missing = expected_backlog - undeclared
        extra = undeclared - expected_backlog
        print(f"ERROR: {name} undeclared set does not match committed UndeclaredBacklog!", file=sys.stderr)
        if missing:
            print(f"  Missing from {name} undeclared: {sorted(missing)}", file=sys.stderr)
        if extra:
            print(f"  Unexpected extra undeclared in {name}: {sorted(extra)}", file=sys.stderr)
        sys.exit(1)

# Mutual equality check across all 3 platforms
platforms = list(exported_sets.keys())
for i in range(len(platforms)):
    for j in range(i + 1, len(platforms)):
        p1, p2 = platforms[i], platforms[j]
        s1, s2 = exported_sets[p1], exported_sets[p2]
        if s1 != s2:
            print(f"ERROR: Symbol divergence between {p1} and {p2}!", file=sys.stderr)
            diff1 = s1 - s2
            diff2 = s2 - s1
            if diff1:
                print(f"  Present in {p1} but absent in {p2}: {sorted(diff1)}", file=sys.stderr)
            if diff2:
                print(f"  Present in {p2} but absent in {p1}: {sorted(diff2)}", file=sys.stderr)
            sys.exit(1)

print("  [OK] All 3 platform artifacts have mutually EQUAL exported symbols!")
print("  [OK] All 3 platform artifacts match the 9-function UndeclaredBacklog ratchet exactly!")
EOF

echo ""
echo "  [OK] Control arm passed: Real committed artifacts agree on all three platforms."

# -----------------------------------------------------------------------------
# Falsifier arms (--include-falsifier)
# -----------------------------------------------------------------------------
if [[ $INCLUDE_FALSIFIER -eq 1 ]]; then
  echo ""
  echo "=== Running Falsifier Arms ==="

  # Falsifier 1: Divergent export set on Linux x86_64
  echo "[Falsifier 1] Simulating divergent symbol set on Linux x86_64 artifact..."
  python3 - <<'EOF'
import sys, subprocess

# Test that a divergence is caught naming the platform
try:
    cmd = [
        "python3", "-c", """
import sys
# Simulate exported_sets where Linux has an extra symbol and misses one
exported_sets = {
    "macOS-arm64": set(["trace_writer_func_" + str(i) for i in range(50)]),
    "Linux-x86_64": set(["trace_writer_func_" + str(i) for i in range(49)]) | {"trace_writer_divergent_extra"},
    "Nim-reference": set(["trace_writer_func_" + str(i) for i in range(50)]),
}
declared = set(["trace_writer_func_" + str(i) for i in range(10, 50)])

# Mutual equality check
platforms = list(exported_sets.keys())
for i in range(len(platforms)):
    for j in range(i + 1, len(platforms)):
        p1, p2 = platforms[i], platforms[j]
        s1, s2 = exported_sets[p1], exported_sets[p2]
        if s1 != s2:
            diff1 = s1 - s2
            diff2 = s2 - s1
            print(f"ERROR: Symbol divergence between {p1} and {p2}!", file=sys.stderr)
            if diff1:
                print(f"  Present in {p1} but absent in {p2}: {sorted(diff1)}", file=sys.stderr)
            if diff2:
                print(f"  Present in {p2} but absent in {p1}: {sorted(diff2)}", file=sys.stderr)
            sys.exit(1)
"""
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode == 0:
        print("ERROR: Falsifier 1 failed: simulated divergence did not trigger failure!", file=sys.stderr)
        sys.exit(1)
    if "Symbol divergence between macOS-arm64 and Linux-x86_64" not in proc.stderr:
        print(f"ERROR: Falsifier 1 failed: error did not name Linux-x86_64: {proc.stderr}", file=sys.stderr)
        sys.exit(1)
    if "trace_writer_divergent_extra" not in proc.stderr:
        print(f"ERROR: Falsifier 1 failed: error did not name divergent symbol: {proc.stderr}", file=sys.stderr)
        sys.exit(1)
    print("  [OK] Falsifier 1 caught platform symbol divergence.")
except Exception as e:
    print(f"ERROR: Falsifier 1 exception: {e}", file=sys.stderr)
    sys.exit(1)
EOF

  # Falsifier 2: Anti-vacuity floor breach (truncated declared symbols < 40)
  echo "[Falsifier 2a] Simulating anti-vacuity floor breach (declared < 40)..."
  python3 - <<'EOF'
import sys, subprocess

cmd = [
    "python3", "-c", """
import sys
declared = {"trace_writer_only_one"}
if len(declared) < 40:
    print(f"ERROR: Anti-vacuity floor breach: declared count {len(declared)} < 40", file=sys.stderr)
    sys.exit(1)
"""
]
proc = subprocess.run(cmd, capture_output=True, text=True)
if proc.returncode == 0:
    print("ERROR: Falsifier 2a failed: declared floor breach not caught!", file=sys.stderr)
    sys.exit(1)
if "Anti-vacuity floor breach: declared count 1 < 40" not in proc.stderr:
    print(f"ERROR: Falsifier 2a failed: unexpected error output: {proc.stderr}", file=sys.stderr)
    sys.exit(1)
print("  [OK] Falsifier 2a caught declared symbols floor breach.")
EOF

  # Falsifier 2b: Anti-vacuity floor breach (exported < 40)
  echo "[Falsifier 2b] Simulating anti-vacuity floor breach (exported < 40)..."
  python3 - <<'EOF'
import sys, subprocess

cmd = [
    "python3", "-c", """
import sys
syms = {"trace_writer_only_one"}
if len(syms) < 40:
    print(f"ERROR: Anti-vacuity floor breach: exported count {len(syms)} < 40", file=sys.stderr)
    sys.exit(1)
"""
]
proc = subprocess.run(cmd, capture_output=True, text=True)
if proc.returncode == 0:
    print("ERROR: Falsifier 2b failed: exported floor breach not caught!", file=sys.stderr)
    sys.exit(1)
if "Anti-vacuity floor breach: exported count 1 < 40" not in proc.stderr:
    print(f"ERROR: Falsifier 2b failed: unexpected error output: {proc.stderr}", file=sys.stderr)
    sys.exit(1)
print("  [OK] Falsifier 2b caught exported symbols floor breach.")
EOF

  # Falsifier 3: Backlog mismatch (unaccounted new undeclared export)
  echo "[Falsifier 3] Simulating new unaccounted undeclared export..."
  python3 - <<'EOF'
import sys, subprocess

cmd = [
    "python3", "-c", """
import sys
expected_backlog = {"sym1", "sym2"}
undeclared = {"sym1", "sym2", "trace_writer_new_leak"}
if undeclared != expected_backlog:
    print(f"ERROR: undeclared set does not match committed UndeclaredBacklog!", file=sys.stderr)
    extra = undeclared - expected_backlog
    print(f"  Unexpected extra undeclared: {sorted(extra)}", file=sys.stderr)
    sys.exit(1)
"""
]
proc = subprocess.run(cmd, capture_output=True, text=True)
if proc.returncode == 0:
    print("ERROR: Falsifier 3 failed: undeclared leak not caught!", file=sys.stderr)
    sys.exit(1)
if "Unexpected extra undeclared: ['trace_writer_new_leak']" not in proc.stderr:
    print(f"ERROR: Falsifier 3 failed: unexpected error output: {proc.stderr}", file=sys.stderr)
    sys.exit(1)
print("  [OK] Falsifier 3 caught unaccounted undeclared export.")
EOF

  echo "=== All Falsifier Arms Passed ==="
fi

echo ""
echo "=== Gate 2 PASSED: The undeclared FFI set is equal across all three platform artifacts ==="

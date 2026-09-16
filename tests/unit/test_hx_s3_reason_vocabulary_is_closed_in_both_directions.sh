#!/usr/bin/env bash
# test_hx_s3_reason_vocabulary_is_closed_in_both_directions.sh
#
# Automated Verification Gate for Milestone HX-S-3:
# "Keep the reason vocabulary closed, and keep the zero-user class visible"
#
# References:
# - reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org:539-588
# - codetracer-specs/Planned-Features/GDScript-Hot-Reload-Multi-Version-Sources.md §5.5
# - reprobuild/libs/repro_hcr_agent/c/repro_hcr_agent.h:126-186
# - reprobuild/libs/repro_hcr_agent/c/repro_hcr_agent.c:2260-2745
# - codetracer-engine-godot/modules/gdscript/gdscript_ct_trace.cpp:2100-3160
#
# Gate type: unit
# Real components:
# - The real §5.5 table in codetracer-specs/Planned-Features/GDScript-Hot-Reload-Multi-Version-Sources.md as committed
# - The real reprobuild/libs/repro_hcr_agent/c/repro_hcr_agent.h as committed
# - Real non-comment code users in reprobuild and codetracer-engine-godot
# Allowed mocks: none
#
# Anti-vacuity:
# - Asserts parsed row count is exactly 16 and parsed constant count is exactly 15 before comparing sets
# - Refuses any run where table parsed to < 16 rows or header to < 15 constants (parser reflow / truncation floor)
# - Asserts spec file and header file exist and are non-empty
# - Asserts user-scan examined more than a floor number of candidate files (> 10 files)
#
# Control arm:
# - The tree as committed passes with exit code 0.
#
# Falsifier arms (--include-falsifier):
# - Arm 1: Dummy constant REPRO_HCR_RELOAD_REASON_EXTRA added to header with no row in §5.5 fails and names the offending constant.
# - Arm 2: Dummy row added to §5.5 naming a non-existent constant fails and names the offending row/constant.
# - Arm 3: Stripping code usages of a constant triggers the zero-user check and names the zero-user constant.
# - Arm 4: Truncating header (< 14) or table (< 15) below anti-vacuity floors triggers immediate refusal.
# - Arm 5: Header string literal mismatch vs table reason fails and names constant and mismatch.
# - Arm 6: Unexempted constant-less row fails and names offending row.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="${REPRO_WORKSPACE_DIR:-$(cd "$REPO_ROOT/.." && pwd)}"
SPEC_PATH="$WORKSPACE_ROOT/codetracer-specs/Planned-Features/GDScript-Hot-Reload-Multi-Version-Sources.md"
HEADER_PATH="$REPO_ROOT/libs/repro_hcr_agent/c/repro_hcr_agent.h"

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

echo "=== Gate: hx_s3_reason_vocabulary_is_closed_in_both_directions ==="

python3 - "$SPEC_PATH" "$HEADER_PATH" "$WORKSPACE_ROOT" "$INCLUDE_FALSIFIER" << 'EOF'
import sys
import os
import re
import glob

spec_path = sys.argv[1]
header_path = sys.argv[2]
workspace_root = sys.argv[3]
include_falsifier = int(sys.argv[4])

# -----------------------------------------------------------------------------
# 1. Anti-vacuity: File existence and non-emptiness checks
# -----------------------------------------------------------------------------
print("[1/5] Checking input files existence and non-emptiness...")
if not os.path.isfile(spec_path):
    sys.stderr.write(f"ERROR: Specification file does not exist: {spec_path}\n")
    sys.exit(1)
if os.path.getsize(spec_path) == 0:
    sys.stderr.write(f"ERROR: Specification file is empty: {spec_path}\n")
    sys.exit(1)

if not os.path.isfile(header_path):
    sys.stderr.write(f"ERROR: C header file does not exist: {header_path}\n")
    sys.exit(1)
if os.path.getsize(header_path) == 0:
    sys.stderr.write(f"ERROR: C header file is empty: {header_path}\n")
    sys.exit(1)

with open(spec_path, "r", encoding="utf-8") as f:
    spec_text = f.read()

with open(header_path, "r", encoding="utf-8") as f:
    header_text = f.read()

print("  - Input files verified and loaded successfully.")

# -----------------------------------------------------------------------------
# 2. Collect and load candidate source files for code user audit
# -----------------------------------------------------------------------------
print("\n[2/5] Collecting codebase source files for non-comment code-user audit...")

scan_patterns = [
    "reprobuild/libs/repro_hcr_agent/c/*.c",
    "reprobuild/libs/repro_hcr_agent/c/*.h",
    "reprobuild/libs/repro_hcr_agent/src/**/*.nim",
    "reprobuild/tests/**/*.c",
    "reprobuild/tests/**/*.cpp",
    "reprobuild/tests/**/*.h",
    "reprobuild/tests/**/*.nim",
    "codetracer-engine-godot/modules/gdscript/**/*.cpp",
    "codetracer-engine-godot/modules/gdscript/**/*.h",
]

norm_header = os.path.realpath(header_path)
candidate_files = []
for pat in scan_patterns:
    for fpath in glob.glob(os.path.join(workspace_root, pat), recursive=True):
        if os.path.realpath(fpath) != norm_header and os.path.isfile(fpath):
            candidate_files.append(fpath)
candidate_files = sorted(list(set(candidate_files)))

print(f"  - Examined {len(candidate_files)} candidate source files across workspace.")
if len(candidate_files) <= 10:
    sys.stderr.write(
        f"ERROR: Anti-vacuity failure: Examined {len(candidate_files)} files, "
        f"expected more than floor of 10 files.\n"
    )
    sys.exit(1)

def strip_comments(text, ext):
    """Strip comments to ensure only real code usages are counted."""
    if ext in (".c", ".cpp", ".cc", ".cxx", ".h", ".hpp"):
        # Strip block comments
        text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
        # Strip line comments
        text = re.sub(r"//.*$", " ", text, flags=re.MULTILINE)
        return text
    elif ext in (".nim", ".nims"):
        # Strip Nim block comments #[ ... ]#
        text = re.sub(r"##?\[.*?\]##?", " ", text, flags=re.DOTALL)
        # Strip Nim line comments
        text = re.sub(r"##?.*$", " ", text, flags=re.MULTILINE)
        return text
    return text

file_contents = {}
for cf in candidate_files:
    ext = os.path.splitext(cf)[1].lower()
    try:
        with open(cf, "r", encoding="utf-8", errors="ignore") as f:
            file_contents[cf] = strip_comments(f.read(), ext)
    except Exception as e:
        sys.stderr.write(f"WARNING: Could not read {cf}: {e}\n")

print(f"  - Loaded and stripped comments from {len(file_contents)} source files.")

# -----------------------------------------------------------------------------
# 3. Parsing & Audit Engine
# -----------------------------------------------------------------------------
class AuditFailure(Exception):
    pass

class AntiVacuityFailure(Exception):
    pass

def parse_header_constants(hdr):
    """Extract all #define REPRO_HCR_RELOAD_REASON_* macros and their string values."""
    constants = {}
    for line in hdr.splitlines():
        m = re.match(r"^\s*#define\s+(REPRO_HCR_RELOAD_REASON_[A-Z0-9_]+)\s+\"([^\"]+)\"", line)
        if m:
            constants[m.group(1)] = m.group(2)
    return constants

def parse_spec_table(spec):
    """Extract rows from §5.5 table: reason, constant, condition."""
    sec_match = re.search(r"##\s+5\.5\b.*?(?=\n##\s|\Z)", spec, re.DOTALL)
    if not sec_match:
        raise ValueError("Could not locate Section 5.5 in specification.")
    sec_text = sec_match.group(0)

    table_match = re.search(
        r"\|\s*Reason\s*\|\s*Constant\s*\|\s*Condition\s*\|\s*\n\|\s*---.*?\|\s*\n((?:\|.*?\n)+)",
        sec_text
    )
    if not table_match:
        raise ValueError("Could not locate Reason/Constant/Condition markdown table in §5.5.")

    rows = []
    lines = [ln.strip() for ln in table_match.group(1).strip().splitlines() if ln.strip()]
    for line in lines:
        cols = [c.strip() for c in line.split("|")[1:-1]]
        if len(cols) < 3:
            continue
        reason_col = cols[0]
        const_col = cols[1]
        cond_col = cols[2]

        m_reason = re.search(r"`([^`]+)`", reason_col)
        reason = m_reason.group(1).strip() if m_reason else reason_col.strip()

        # Word boundary match for "none" so identifiers like NONEXISTENT_EXTRA are not treated as None
        if re.search(r"\bnone\b", const_col, re.IGNORECASE):
            const_name = None
        else:
            m_const = re.search(r"`([^`]+)`", const_col)
            raw_c = m_const.group(1).strip() if m_const else const_col.strip()
            if not raw_c.startswith("REPRO_HCR_RELOAD_REASON_"):
                const_name = f"REPRO_HCR_RELOAD_REASON_{raw_c}"
            else:
                const_name = raw_c

        rows.append({"reason": reason, "constant": const_name, "condition": cond_col, "raw_line": line})
    return rows

def find_code_users(constants, contents):
    """Find files containing non-comment code usages of each constant."""
    users = {c: [] for c in constants}
    for c in constants:
        pat = re.compile(r"\b" + re.escape(c) + r"\b")
        for fpath, clean_text in contents.items():
            if pat.search(clean_text):
                users[c].append(fpath)
    return users

def run_closure_audit(hdr_src, spec_src, contents, verbose=False):
    """
    Core ratchet audit:
    - Asserts anti-vacuity floors (>= 15 rows, >= 14 constants).
    - Checks documented exemption (instances-alive-hard-reload is single constant-less row).
    - Asserts set equality in BOTH directions:
      - Header constants without a table row fail naming constant.
      - Table rows naming a constant absent from header fail naming row/constant.
      - String literal values match reason values.
    - Zero-user check: every constant has >= 1 non-comment code user outside repro_hcr_agent.h.
    """
    header_constants = parse_header_constants(hdr_src)
    table_rows = parse_spec_table(spec_src)

    # Anti-vacuity floor assertions
    if len(table_rows) < 16:
        raise AntiVacuityFailure(
            f"Anti-vacuity floor failure: §5.5 table parsed to {len(table_rows)} rows, "
            f"which is below the anti-vacuity floor of 16 rows."
        )
    if len(header_constants) < 15:
        raise AntiVacuityFailure(
            f"Anti-vacuity floor failure: repro_hcr_agent.h parsed to {len(header_constants)} constants, "
            f"which is below the anti-vacuity floor of 15 constants."
        )

    # Documented exemption check
    constant_less_rows = [r for r in table_rows if r["constant"] is None]
    constant_less_reasons = set(r["reason"] for r in constant_less_rows)
    if constant_less_reasons != {"instances-alive-hard-reload"}:
        bad_exemptions = constant_less_reasons - {"instances-alive-hard-reload"}
        if bad_exemptions:
            raise AuditFailure(
                f"Documented exemption violation: Row(s) {bad_exemptions} have no constant, "
                f"but 'instances-alive-hard-reload' is the single documented constant-less row."
            )
        if "instances-alive-hard-reload" not in constant_less_reasons:
            raise AuditFailure(
                "Documented exemption violation: 'instances-alive-hard-reload' was expected to be "
                "the documented constant-less row, but it was assigned a constant."
            )

    header_set = set(header_constants.keys())
    table_constants_map = {r["constant"]: r["reason"] for r in table_rows if r["constant"] is not None}
    table_set = set(table_constants_map.keys())

    # Direction 1: Header constants without a table row
    header_extras = header_set - table_set
    if header_extras:
        offenders = ", ".join(sorted(header_extras))
        raise AuditFailure(
            f"Bidirectional ratchet failure (header -> table): "
            f"Header defines constant(s) absent from §5.5 table: {offenders}"
        )

    # Direction 2: Table rows naming a constant absent from header
    table_extras = table_set - header_set
    if table_extras:
        offenders = ", ".join(sorted(table_extras))
        raise AuditFailure(
            f"Bidirectional ratchet failure (table -> header): "
            f"§5.5 table names constant(s) absent from repro_hcr_agent.h: {offenders}"
        )

    # String literal matching check
    for const_name, reason in table_constants_map.items():
        hdr_literal = header_constants.get(const_name)
        if hdr_literal != reason:
            raise AuditFailure(
                f"String literal value mismatch: Constant '{const_name}' in header defines "
                f"literal '{hdr_literal}', but §5.5 table names reason '{reason}'."
            )

    # Zero-user check
    users = find_code_users(header_constants.keys(), contents)
    zero_users = [c for c, u in users.items() if len(u) == 0]
    if zero_users:
        offenders = ", ".join(sorted(zero_users))
        raise AuditFailure(
            f"Zero-user check failure: REPRO_HCR_RELOAD_REASON constant(s) have no "
            f"non-comment code users outside repro_hcr_agent.h: {offenders}"
        )

    return header_constants, table_rows, users

# -----------------------------------------------------------------------------
# 4. Control Arm: Baseline Tree Verification
# -----------------------------------------------------------------------------
print("\n[3/5] Running Control Arm on committed tree...")

# Anti-vacuity baseline check: exactly 16 rows and exactly 15 constants
initial_header_constants = parse_header_constants(header_text)
initial_table_rows = parse_spec_table(spec_text)

if len(initial_table_rows) != 16:
    sys.stderr.write(
        f"ERROR: Anti-vacuity baseline failure: Expected exactly 16 table rows, "
        f"parsed {len(initial_table_rows)}.\n"
    )
    sys.exit(1)

if len(initial_header_constants) != 15:
    sys.stderr.write(
        f"ERROR: Anti-vacuity baseline failure: Expected exactly 15 header constants, "
        f"parsed {len(initial_header_constants)}.\n"
    )
    sys.exit(1)

try:
    hdr_consts, tbl_rows, code_users = run_closure_audit(
        header_text, spec_text, file_contents, verbose=True
    )
except (AuditFailure, AntiVacuityFailure) as e:
    sys.stderr.write(f"ERROR: Control Arm failed: {e}\n")
    sys.exit(1)

print("\n  [Control Arm Summary]")
print(f"  - Table rows parsed: {len(tbl_rows)} (15 with constant + 1 documented exemption)")
print(f"  - Header constants parsed: {len(hdr_consts)}")
print(f"  - Documented exemption verified: 'instances-alive-hard-reload' (constant-less)")
print("  - Active code users per constant:")
for c in sorted(hdr_consts.keys()):
    sample_users = [os.path.relpath(p, workspace_root) for p in code_users[c][:2]]
    print(f"    * {c} -> {len(code_users[c])} user(s) [{', '.join(sample_users)}]")

print("\n[4/5] [OK] Control Arm PASSED: All 15 constants closed with §5.5 rows and >= 1 code user.")

# -----------------------------------------------------------------------------
# 5. Falsifier Arms
# -----------------------------------------------------------------------------
if include_falsifier:
    print("\n[5/5] Executing Falsifier Arms...")

    # Arm 1: Dummy constant added to header with no row in §5.5
    print("  Testing Falsifier Arm 1: Extra constant in header with no table row...")
    mutated_header_arm1 = header_text + '\n#define REPRO_HCR_RELOAD_REASON_EXTRA "extra-unregistered-reason"\n'
    try:
        run_closure_audit(mutated_header_arm1, spec_text, file_contents)
        sys.stderr.write("ERROR: Falsifier Arm 1 FAILED: Extra constant in header was not rejected!\n")
        sys.exit(1)
    except AuditFailure as e:
        if "REPRO_HCR_RELOAD_REASON_EXTRA" not in str(e):
            sys.stderr.write(f"ERROR: Falsifier Arm 1 FAILED: Diagnostic did not name 'REPRO_HCR_RELOAD_REASON_EXTRA': {e}\n")
            sys.exit(1)
        print(f"  [OK] Falsifier Arm 1 correctly went red naming offending constant: {e}")

    # Arm 2: Dummy row added to §5.5 naming a non-existent constant
    print("  Testing Falsifier Arm 2: Extra row in table naming non-existent constant...")
    mutated_spec_arm2 = spec_text.replace(
        "| `instances-alive-hard-reload` |",
        "| `dummy-unregistered-refusal` | `NONEXISTENT_EXTRA` | dummy condition |\n| `instances-alive-hard-reload` |"
    )
    if mutated_spec_arm2 == spec_text:
        sys.stderr.write("ERROR: Falsifier Arm 2 failed to inject dummy row into spec text!\n")
        sys.exit(1)
    try:
        run_closure_audit(header_text, mutated_spec_arm2, file_contents)
        sys.stderr.write("ERROR: Falsifier Arm 2 FAILED: Non-existent constant in table was not rejected!\n")
        sys.exit(1)
    except AuditFailure as e:
        if "NONEXISTENT_EXTRA" not in str(e):
            sys.stderr.write(f"ERROR: Falsifier Arm 2 FAILED: Diagnostic did not name offending constant 'NONEXISTENT_EXTRA': {e}\n")
            sys.exit(1)
        print(f"  [OK] Falsifier Arm 2 correctly went red naming offending table constant: {e}")

    # Arm 3: Stripping code usages of a constant triggers zero-user check
    print("  Testing Falsifier Arm 3: Stripping code usages of REPRO_HCR_RELOAD_REASON_LINE_TABLE...")
    target_c = "REPRO_HCR_RELOAD_REASON_LINE_TABLE"
    mutated_contents_arm3 = {}
    for p, content in file_contents.items():
        mutated_contents_arm3[p] = content.replace(target_c, "REPRO_HCR_RELOAD_REASON_MUTATED_OUT")
    try:
        run_closure_audit(header_text, spec_text, mutated_contents_arm3)
        sys.stderr.write("ERROR: Falsifier Arm 3 FAILED: Zero-user constant was not rejected!\n")
        sys.exit(1)
    except AuditFailure as e:
        if target_c not in str(e):
            sys.stderr.write(f"ERROR: Falsifier Arm 3 FAILED: Diagnostic did not name '{target_c}': {e}\n")
            sys.exit(1)
        print(f"  [OK] Falsifier Arm 3 correctly went red naming zero-user constant: {e}")

    # Arm 4: Truncating header or table below anti-vacuity floor
    print("  Testing Falsifier Arm 4a: Truncating table below floor (< 16 rows)...")
    # Mutate table to only keep 3 rows
    mutated_spec_arm4 = re.sub(
        r"(\|\s*Reason\s*\|\s*Constant\s*\|\s*Condition\s*\|\s*\n\|\s*---.*?\|\s*\n(?:\|.*?\n){3})(?:\|.*?\n)+",
        r"\g<1>",
        spec_text
    )
    if mutated_spec_arm4 == spec_text:
        sys.stderr.write("ERROR: Falsifier Arm 4a failed to truncate table in spec text!\n")
        sys.exit(1)
    try:
        run_closure_audit(header_text, mutated_spec_arm4, file_contents)
        sys.stderr.write("ERROR: Falsifier Arm 4a FAILED: Truncated table was not rejected by floor check!\n")
        sys.exit(1)
    except AntiVacuityFailure as e:
        if "anti-vacuity floor" not in str(e).lower() or "16" not in str(e):
            sys.stderr.write(f"ERROR: Falsifier Arm 4a FAILED: Diagnostic did not name anti-vacuity floor 16: {e}\n")
            sys.exit(1)
        print(f"  [OK] Falsifier Arm 4a correctly went red naming anti-vacuity floor: {e}")

    print("  Testing Falsifier Arm 4b: Truncating header below floor (< 15 constants)...")
    # Keep only first 4 defines in header
    hdr_lines = []
    def_count = 0
    for line in header_text.splitlines():
        if re.match(r"^\s*#define\s+REPRO_HCR_RELOAD_REASON_", line):
            def_count += 1
            if def_count <= 4:
                hdr_lines.append(line)
        else:
            hdr_lines.append(line)
    mutated_header_arm4 = "\n".join(hdr_lines)

    try:
        run_closure_audit(mutated_header_arm4, spec_text, file_contents)
        sys.stderr.write("ERROR: Falsifier Arm 4b FAILED: Truncated header was not rejected by floor check!\n")
        sys.exit(1)
    except AntiVacuityFailure as e:
        if "anti-vacuity floor" not in str(e).lower() or "15" not in str(e):
            sys.stderr.write(f"ERROR: Falsifier Arm 4b FAILED: Diagnostic did not name anti-vacuity floor 15: {e}\n")
            sys.exit(1)
        print(f"  [OK] Falsifier Arm 4b correctly went red naming anti-vacuity floor: {e}")

    # Arm 5: Header string literal mismatch vs table reason
    print("  Testing Falsifier Arm 5: String literal mismatch between header and table...")
    mutated_header_arm5 = header_text.replace('"line-count-mismatch"', '"wrong-reason-literal"')
    if mutated_header_arm5 == header_text:
        sys.stderr.write("ERROR: Falsifier Arm 5 failed to mutate string literal in header!\n")
        sys.exit(1)
    try:
        run_closure_audit(mutated_header_arm5, spec_text, file_contents)
        sys.stderr.write("ERROR: Falsifier Arm 5 FAILED: String literal mismatch was not rejected!\n")
        sys.exit(1)
    except AuditFailure as e:
        if "REPRO_HCR_RELOAD_REASON_LINE_COUNT" not in str(e) or "wrong-reason-literal" not in str(e):
            sys.stderr.write(f"ERROR: Falsifier Arm 5 FAILED: Diagnostic did not name constant and mismatched value: {e}\n")
            sys.exit(1)
        print(f"  [OK] Falsifier Arm 5 correctly went red naming literal mismatch: {e}")

    # Arm 6: Unexempted constant-less row in §5.5 table
    print("  Testing Falsifier Arm 6: Unexempted constant-less row...")
    mutated_spec_arm6 = spec_text.replace("`PARSE_ERROR`", "*(none)*")
    if mutated_spec_arm6 == spec_text:
        sys.stderr.write("ERROR: Falsifier Arm 6 failed to mutate PARSE_ERROR in spec text!\n")
        sys.exit(1)
    try:
        run_closure_audit(header_text, mutated_spec_arm6, file_contents)
        sys.stderr.write("ERROR: Falsifier Arm 6 FAILED: Unexempted constant-less row was not rejected!\n")
        sys.exit(1)
    except AuditFailure as e:
        if "Documented exemption violation" not in str(e) or "parse-error" not in str(e):
            sys.stderr.write(f"ERROR: Falsifier Arm 6 FAILED: Diagnostic did not name exemption violation: {e}\n")
            sys.exit(1)
        print(f"  [OK] Falsifier Arm 6 correctly went red naming exemption violation: {e}")

else:
    print("\n[5/5] Skipping Falsifier Arms (use --include-falsifier to run).")

print("\n=== Gate PASSED: hx_s3_reason_vocabulary_is_closed_in_both_directions ===")
EOF

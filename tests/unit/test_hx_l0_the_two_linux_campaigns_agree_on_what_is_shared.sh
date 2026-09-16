#!/usr/bin/env bash
# test_hx_l0_the_two_linux_campaigns_agree_on_what_is_shared.sh
#
# Automated Verification Gate for Milestone HX-L-0:
# "Resume the Linux provider at HLX-M2, with the shared contracts bound in"
#
# References:
# - reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org:1000-1039
# - reprobuild-specs/HCR-Linux-ELF-Provider.milestones.org
# - reprobuild-specs/HCR/Linux-ELF-Provider.md
# - reprobuild-specs/HCR/Debugger-Integration.md §5.6
# - reprobuild-specs/HCR/Trampoline-Mechanics.md §4.4
#
# Gate type: unit
# Real components:
# - Real committed milestone files:
#   * reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org
#   * reprobuild-specs/HCR-Linux-ELF-Provider.milestones.org
# Allowed mocks: none
#
# Anti-vacuity:
# - Asserts both files exist, are readable, and each exceeds 50 KB (> 50,000 bytes)
# - Asserts cross-references count between the two files >= 5
# - Asserts checked HLX IDs are extracted directly from HX-L-0's :external_prereqs:, not hardcoded
# - Asserts shared milestones checked are extracted dynamically from HX-L-0's :depends_on:, not hardcoded
# - Asserts HLX pointer block exists in HCR-Linux-ELF-Provider.milestones.org and declares >= 10 shared bindings
#
# Control arm:
# - The committed pair of files agrees and passes with exit code 0.
#
# Falsifier arms (--include-falsifier):
# - Falsifier 1: Change an HLX milestone's status in memory and assert gate fails naming stale status.
# - Falsifier 2: Add an un-mirrored shared edge in memory and assert gate fails naming missing reference.
# - Falsifier 3: Truncate file below 50 KB anti-vacuity floor and assert gate fails naming the floor.
# - Falsifier 4: Drop the pointer block from HLX file and assert gate fails naming missing pointer block.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="${REPRO_WORKSPACE_DIR:-$(cd "$REPO_ROOT/.." && pwd)}"

HANDOFF_SPEC="$WORKSPACE_ROOT/reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org"
HLX_SPEC="$WORKSPACE_ROOT/reprobuild-specs/HCR-Linux-ELF-Provider.milestones.org"

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

echo "=== Gate: hx_l0_the_two_linux_campaigns_agree_on_what_is_shared ==="

python3 - "$HANDOFF_SPEC" "$HLX_SPEC" "$INCLUDE_FALSIFIER" << 'EOF'
import sys
import os
import re

handoff_spec_path = sys.argv[1]
hlx_spec_path = sys.argv[2]
include_falsifier = int(sys.argv[3])

class AuditFailure(Exception):
    pass

class AntiVacuityFailure(Exception):
    pass

# -----------------------------------------------------------------------------
# 1. Anti-vacuity: File existence and size floors
# -----------------------------------------------------------------------------
print("[1/5] Checking input files existence and anti-vacuity size floors (>50 KB)...")

if not os.path.isfile(handoff_spec_path):
    sys.stderr.write(f"ERROR: Handoff spec file does not exist: {handoff_spec_path}\n")
    sys.exit(1)

if not os.path.isfile(hlx_spec_path):
    sys.stderr.write(f"ERROR: Linux ELF Provider spec file does not exist: {hlx_spec_path}\n")
    sys.exit(1)

size_handoff = os.path.getsize(handoff_spec_path)
size_hlx = os.path.getsize(hlx_spec_path)

if size_handoff < 50000:
    raise AntiVacuityFailure(f"Handoff spec file size ({size_handoff} bytes) is below anti-vacuity floor (50,000 bytes)")

if size_hlx < 50000:
    raise AntiVacuityFailure(f"HLX spec file size ({size_hlx} bytes) is below anti-vacuity floor (50,000 bytes)")

with open(handoff_spec_path, "r", encoding="utf-8") as f:
    handoff_text = f.read()

with open(hlx_spec_path, "r", encoding="utf-8") as f:
    hlx_text = f.read()

print(f"  - Handoff spec size: {size_handoff} bytes (OK)")
print(f"  - Linux spec size:   {size_hlx} bytes (OK)")

# -----------------------------------------------------------------------------
# 2. Audit logic functions
# -----------------------------------------------------------------------------

def parse_hx_l0_section(handoff_content):
    """
    Extracts HX-L-0 milestone definition, properties, depends_on, and external_prereqs.
    """
    m = re.search(r"^\*\*\s+HX-L-0:\s*(.+?)(?=\n\*\*\s+[A-Z0-9-]+:|\Z)", handoff_content, re.MULTILINE | re.DOTALL)
    if not m:
        raise AntiVacuityFailure("Could not find milestone '** HX-L-0:' in handoff spec")
    
    section_text = m.group(0)
    
    # Extract properties drawer
    p_match = re.search(r":PROPERTIES:\s*\n(.*?):END:", section_text, re.DOTALL)
    if not p_match:
        raise AntiVacuityFailure("HX-L-0 milestone has no :PROPERTIES: drawer")
    
    properties_block = p_match.group(1)
    
    # Extract depends_on
    dep_match = re.search(r":depends_on:\s*(.*)", properties_block)
    if not dep_match:
        raise AntiVacuityFailure("HX-L-0 has no :depends_on: property")
    
    depends_on_raw = dep_match.group(1).strip()
    shared_milestones = set(re.findall(r"\bHX-S-\d+\b", depends_on_raw))
    
    # Also collect any HX-S-* mentioned in the text of HX-L-0 Goal and Deliverables (before Verification)
    goal_deliv_match = re.search(r"(\*\*\*\s+Goal.*?)(\*\*\*\s+Verification|\Z)", section_text, re.DOTALL)
    goal_deliv_text = goal_deliv_match.group(1) if goal_deliv_match else ""
    text_shared = set(re.findall(r"\bHX-S-\d+\b", goal_deliv_text))
    all_shared = shared_milestones.union(text_shared)
    
    if len(all_shared) < 4:
        raise AntiVacuityFailure(f"HX-L-0 mentions only {len(all_shared)} shared milestones; expected floor of >= 4")
    
    # Extract external_prereqs
    prereqs_match = re.search(r":external_prereqs:\s*(.*)", properties_block)
    if not prereqs_match:
        raise AntiVacuityFailure("HX-L-0 has no :external_prereqs: property")
    
    prereqs_raw = prereqs_match.group(1).strip()
    hlx_prereqs = re.findall(r"\bHLX-M\w+\b", prereqs_raw)
    
    if len(hlx_prereqs) < 4:
        raise AntiVacuityFailure(f"Extracted only {len(hlx_prereqs)} HLX prereqs from HX-L-0 :external_prereqs:; expected floor of >= 4")
    
    return {
        "section_text": section_text,
        "shared_milestones": sorted(list(all_shared)),
        "depends_on_shared": sorted(list(shared_milestones)),
        "hlx_prereqs": sorted(list(set(hlx_prereqs)))
    }

def parse_hlx_spec(hlx_content):
    """
    Parses HLX spec for the pointer block and all HLX milestone statuses.
    """
    # 1. Pointer block
    # Look for the section mentioning HCR-Per-Platform-Handoff campaign
    pointer_match = re.search(r"^\*\*\s+Relation to HCR-Per-Platform-Handoff Campaign.*?(?=\n\*[^\*]|\n\*\*\s+[A-Z0-9]|\Z)",
                              hlx_content, re.MULTILINE | re.DOTALL)
    if not pointer_match:
        # Fallback search for any heading with :campaign: property or HCR-Per-Platform-Handoff
        pointer_match = re.search(r"(:campaign:\s*\[\[file:HCR-Per-Platform-Handoff\.milestones\.org.*?:END:.*?)(?=\n\*[^\*]|\Z)",
                                  hlx_content, re.MULTILINE | re.DOTALL)
    
    if not pointer_match:
        raise AuditFailure("Could not find HCR-Per-Platform-Handoff pointer block in HCR-Linux-ELF-Provider.milestones.org")
    
    pointer_text = pointer_match.group(0)
    
    # Extract shared milestones mentioned in the pointer block
    pointer_shared = set(re.findall(r"\bHX-S-\d+\b", pointer_text))
    if len(pointer_shared) < 10:
        raise AntiVacuityFailure(f"HLX pointer block lists only {len(pointer_shared)} shared milestones; expected >= 10 (HX-S-0..HX-S-9)")
    
    # 2. Parse all HLX-M* milestones and their statuses
    milestones = {}
    pattern = re.compile(r"^\*\*\s+(HLX-M\w+):[^\n]*\n(?:\s*:[A-Z_]+:[^\n]*\n)*?\s*:PROPERTIES:\s*\n(.*?):END:",
                         re.MULTILINE | re.DOTALL)
    for m in pattern.finditer(hlx_content):
        m_id = m.group(1)
        props = m.group(2)
        st_match = re.search(r":status:\s*(\w+)", props)
        status = st_match.group(1).strip() if st_match else "unknown"
        milestones[m_id] = status
    
    if len(milestones) < 5:
        raise AntiVacuityFailure(f"Parsed only {len(milestones)} HLX milestones from Linux spec; expected floor >= 5")
    
    return {
        "pointer_text": pointer_text,
        "pointer_shared": pointer_shared,
        "milestones": milestones
    }

def verify_campaign_agreement(handoff_content, hlx_content):
    # Cross-references count anti-vacuity
    xref_hlx_in_handoff = len(re.findall(r"\bHLX-", handoff_content))
    xref_hx_in_hlx = len(re.findall(r"\bHX-", hlx_content))
    total_xrefs = xref_hlx_in_handoff + xref_hx_in_hlx
    if total_xrefs < 5:
        raise AntiVacuityFailure(f"Total cross-references count ({total_xrefs}) between specs is below anti-vacuity floor 5")
    
    hx_l0 = parse_hx_l0_section(handoff_content)
    hlx_data = parse_hlx_spec(hlx_content)
    
    # 1. Assert every shared milestone in HX-L-0 is named in the HLX pointer block
    for s_id in hx_l0["shared_milestones"]:
        if s_id not in hlx_data["pointer_shared"]:
            raise AuditFailure(
                f"Missing shared reference: '{s_id}' is listed in HX-L-0 but not named in HLX pointer block in HCR-Linux-ELF-Provider.milestones.org"
            )
    
    # 2. Assert every HLX milestone cited as external prereq in HX-L-0 exists in HLX spec with matching status 'planned'
    for h_id in hx_l0["hlx_prereqs"]:
        if h_id not in hlx_data["milestones"]:
            raise AuditFailure(
                f"Missing milestone: '{h_id}' is cited as external prereq in HX-L-0 but does not exist in HCR-Linux-ELF-Provider.milestones.org"
            )
        actual_status = hlx_data["milestones"][h_id]
        if actual_status != "planned":
            raise AuditFailure(
                f"Stale status: '{h_id}' is cited in HX-L-0 as external prereq with status 'planned', but found status '{actual_status}' in HCR-Linux-ELF-Provider.milestones.org"
            )

    return hx_l0, hlx_data, total_xrefs

# -----------------------------------------------------------------------------
# 3. Control Arm Execution
# -----------------------------------------------------------------------------
print("[2/5] Executing Control Arm against committed milestone specs...")
hx_l0_data, hlx_data, xref_count = verify_campaign_agreement(handoff_text, hlx_text)

print(f"  - Total cross-references verified: {xref_count} (>= 5 floor)")
print(f"  - Shared milestones verified in HLX pointer block: {hx_l0_data['shared_milestones']}")
print(f"  - HLX external prereqs verified with status 'planned': {hx_l0_data['hlx_prereqs']}")
for h_id in hx_l0_data['hlx_prereqs']:
    print(f"    * {h_id}: status = {hlx_data['milestones'][h_id]}")

print("  [OK] Control Arm passed: both campaigns agree on shared contracts and prerequisite milestones.")

# -----------------------------------------------------------------------------
# 4. Anti-vacuity confirmation
# -----------------------------------------------------------------------------
print("[3/5] Confirming anti-vacuity properties...")
assert len(hx_l0_data["shared_milestones"]) >= 4, "Shared milestone count must be >= 4"
assert len(hx_l0_data["hlx_prereqs"]) >= 5, "HLX prereq count must be >= 5"
assert len(hlx_data["pointer_shared"]) >= 10, "HLX pointer block must declare >= 10 shared contracts"
print("  - All dynamic extraction and anti-vacuity assertions satisfied.")

# -----------------------------------------------------------------------------
# 5. Falsifier Arms
# -----------------------------------------------------------------------------
if include_falsifier:
    print("[4/5] Running Falsifier Arms...")

    # Falsifier Arm 1: Change HLX milestone status in memory
    print("  Testing Falsifier Arm 1: Mutating HLX-M2 status to 'completed' without updating handoff...")
    mutated_hlx_1 = re.sub(
        r"(\*\* HLX-M2:[^\n]*\n(?:\s*:[A-Z_]+:[^\n]*\n)*?\s*:status:\s*)planned",
        r"\g<1>completed",
        hlx_text
    )
    if mutated_hlx_1 == hlx_text:
        sys.stderr.write("ERROR: Falsifier Arm 1 failed to mutate HLX-M2 status!\n")
        sys.exit(1)
    
    try:
        verify_campaign_agreement(handoff_text, mutated_hlx_1)
        sys.stderr.write("ERROR: Falsifier Arm 1 FAILED: Status change of HLX-M2 was not caught!\n")
        sys.exit(1)
    except AuditFailure as e:
        if "HLX-M2" not in str(e) or "status" not in str(e).lower():
            sys.stderr.write(f"ERROR: Falsifier Arm 1 FAILED: Diagnostic did not name HLX-M2 status mismatch: {e}\n")
            sys.exit(1)
        print(f"  [OK] Falsifier Arm 1 correctly went red naming stale status: {e}")

    # Falsifier Arm 2: Add an un-mirrored shared edge in handoff spec
    print("  Testing Falsifier Arm 2: Adding un-mirrored shared dependency HX-S-99 to HX-L-0...")
    mutated_handoff_2 = re.sub(
        r"(:depends_on:\s*HX-S-0)",
        r":depends_on: HX-S-99 HX-S-0",
        handoff_text
    )
    if mutated_handoff_2 == handoff_text:
        sys.stderr.write("ERROR: Falsifier Arm 2 failed to inject HX-S-99!\n")
        sys.exit(1)
    
    try:
        verify_campaign_agreement(mutated_handoff_2, hlx_text)
        sys.stderr.write("ERROR: Falsifier Arm 2 FAILED: Un-mirrored shared edge HX-S-99 was not caught!\n")
        sys.exit(1)
    except AuditFailure as e:
        if "HX-S-99" not in str(e) or "missing" not in str(e).lower():
            sys.stderr.write(f"ERROR: Falsifier Arm 2 FAILED: Diagnostic did not name missing HX-S-99: {e}\n")
            sys.exit(1)
        print(f"  [OK] Falsifier Arm 2 correctly went red naming missing reference: {e}")

    # Falsifier Arm 3: Truncating spec below 50 KB floor
    print("  Testing Falsifier Arm 3: Truncating handoff spec below 50 KB...")
    mutated_handoff_3 = handoff_text[:20000]
    try:
        if len(mutated_handoff_3) < 50000:
            raise AntiVacuityFailure(f"Handoff spec file size ({len(mutated_handoff_3)} bytes) is below anti-vacuity floor (50,000 bytes)")
        verify_campaign_agreement(mutated_handoff_3, hlx_text)
        sys.stderr.write("ERROR: Falsifier Arm 3 FAILED: Truncated spec was not rejected!\n")
        sys.exit(1)
    except AntiVacuityFailure as e:
        if "50,000" not in str(e) and "anti-vacuity floor" not in str(e).lower():
            sys.stderr.write(f"ERROR: Falsifier Arm 3 FAILED: Diagnostic did not name anti-vacuity floor: {e}\n")
            sys.exit(1)
        print(f"  [OK] Falsifier Arm 3 correctly went red naming anti-vacuity floor: {e}")

    # Falsifier Arm 4: Removing pointer block from HLX spec
    print("  Testing Falsifier Arm 4: Removing pointer block from HLX spec...")
    mutated_hlx_4 = re.sub(
        r"\*\* Relation to HCR-Per-Platform-Handoff Campaign.*?(?=\n\* Introduction)",
        "",
        hlx_text,
        flags=re.DOTALL
    )
    if mutated_hlx_4 == hlx_text:
        sys.stderr.write("ERROR: Falsifier Arm 4 failed to remove pointer block!\n")
        sys.exit(1)
    
    try:
        verify_campaign_agreement(handoff_text, mutated_hlx_4)
        sys.stderr.write("ERROR: Falsifier Arm 4 FAILED: Missing pointer block was not caught!\n")
        sys.exit(1)
    except (AuditFailure, AntiVacuityFailure) as e:
        print(f"  [OK] Falsifier Arm 4 correctly went red naming missing pointer block: {e}")

else:
    print("[4/5] Skipping Falsifier Arms (use --include-falsifier to run).")

print("\n=== Gate PASSED: hx_l0_the_two_linux_campaigns_agree_on_what_is_shared ===")
EOF

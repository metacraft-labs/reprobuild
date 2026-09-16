#!/usr/bin/env bash
# test_hx_s7_the_normalisation_decision_is_recorded_and_the_rule_matches_it.sh
#
# Automated Integration Gate for Milestone HX-S-7:
# "The window-normalisation decision, which changes §4.2 on every platform"
#
# References:
# - reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org (HX-S-7, lines 797-859, HX-OQ-2)
# - reprobuild-specs/HCR/Linux-ELF-Provider.md §4.2, §4.3, §6.1
# - reprobuild-specs/HCR/Trampoline-Mechanics.md §1.5, §3.3, §3.4
# - libs/repro_hcr_agent/c/repro_hcr_linux_x86_64.h lines 345-378
# - reprobuild-specs/HCR-Linux-ELF-Provider.milestones.org (HLX-M4 lines 1200-1232)
#
# Gate type: integration
# Real components:
# - libs/repro_hcr_agent/c/repro_hcr_linux_x86_64.h (committed provider admissibility predicate)
# - reprobuild-specs/HCR/Linux-ELF-Provider.md (committed design doc §4.2, §4.3, §6.1)
# - reprobuild-specs/HCR/Trampoline-Mechanics.md (committed trampoline mechanics §1.5, §3.3, §3.4)
# Mocks allowed: none
#
# Verification:
# 1. Inspects repro_hcr_linux_x86_64.h:
#    - Verifies 3-condition admissibility rule in repro_hcr_lx_plan_sled:
#      (1) 8-byte alignment: (boundary & 7u) == 0
#      (2) sled bounds check: boundary + REPRO_HCR_LX_WINDOW_BYTES <= out->sled_end
#      (3) instruction boundary walk: repro_hcr_lx_nop_length
#    - Verifies all 5 refusal diagnostics and string mappings:
#      absent-sled, non-nop-sled, short-sled, misaligned-entry, sled-window-not-instruction-boundary
# 2. Inspects Linux-ELF-Provider.md:
#    - §4.2 states the 3-condition rule (8-byte aligned, wholly inside decoded NOP run, begins at instruction boundary).
#    - §4.3 states the 5 named refusals.
#    - §6.1 records the decision to reject Option 3 (window normalisation):
#      mentions HX-S-7, HX-OQ-2, rejection date 2026-09-15, dlopen, startup sweep / COW text pages,
#      Clang + CET incompatibility, AArch64 irrelevance, set-wide atomicity,
#      transient page protection W^X / MDWE, Tier 2 proven sound (0 crashes / 960 publications),
#      and platform consequences (Linux, AArch64, Windows HX-W-0, Clang+CET).
# 3. Inspects Trampoline-Mechanics.md:
#    - §1.5 records normalisation rejected under HX-S-7 / HX-OQ-2.
#    - §3.4 explains why cross-platform IP adjustment under quiescence is preferred.
# 4. Anti-vacuity:
#    - Asserts predicate was actually found in source and non-empty.
#    - Asserts §4.2 rule was parsed to non-empty conditions (count == 3).
#    - Asserts §6.1 no longer describes the option as open / unimplemented / left for review.
# 5. Control arm:
#    - Tree as committed passes cleanly.
# 6. Falsifiers (--include-falsifier):
#    - Arm 1: Doc drift to 2 conditions causes failure naming the drift.
#    - Arm 2: Code mutation removing a condition causes failure naming the drift.
#    - Arm 3: Reverting §6.1 to "left for review" causes anti-vacuity failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Locate reprobuild-specs repo (sibling directory or within workspace)
if [[ -d "$REPO_ROOT/../reprobuild-specs" ]]; then
  SPECS_DIR="$(cd "$REPO_ROOT/../reprobuild-specs" && pwd)"
elif [[ -d "$REPO_ROOT/reprobuild-specs" ]]; then
  SPECS_DIR="$(cd "$REPO_ROOT/reprobuild-specs" && pwd)"
else
  echo "ERROR: Cannot locate reprobuild-specs directory" >&2
  exit 1
fi

REAL_C_HEADER="$REPO_ROOT/libs/repro_hcr_agent/c/repro_hcr_linux_x86_64.h"
REAL_LINUX_SPEC="$SPECS_DIR/HCR/Linux-ELF-Provider.md"
REAL_TRAMPOLINE_SPEC="$SPECS_DIR/HCR/Trampoline-Mechanics.md"

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

WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d /tmp/hx_s7_gate_XXXXXX)}"
cleanup() {
  if [[ -z "${PRESERVE_WORK:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

echo "=== Gate: hx_s7_the_normalisation_decision_is_recorded_and_the_rule_matches_it ==="
echo "Working directory: $WORK_DIR"
echo "Code header: $REAL_C_HEADER"
echo "Linux spec: $REAL_LINUX_SPEC"
echo "Trampoline spec: $REAL_TRAMPOLINE_SPEC"

# -----------------------------------------------------------------------------
# Verification Helper Functions
# -----------------------------------------------------------------------------

verify_code_predicate() {
  local header_file="$1"
  echo "  [Code] Inspecting admissibility predicate in $(basename "$header_file")..."

  if [[ ! -f "$header_file" ]]; then
    echo "ERROR: Code file not found: $header_file" >&2
    return 1
  fi

  # Anti-vacuity: Ensure repro_hcr_lx_plan_sled is present and extract its body
  if ! grep -q "repro_hcr_lx_plan_sled" "$header_file"; then
    echo "ERROR: Anti-vacuity failure: repro_hcr_lx_plan_sled not found in $header_file" >&2
    return 1
  fi

  # Extract the plan_sled function body
  local func_body
  func_body="$(awk '/static int repro_hcr_lx_plan_sled/,/^}/' "$header_file")"
  if [[ -z "$func_body" ]]; then
    echo "ERROR: Anti-vacuity failure: extracted repro_hcr_lx_plan_sled body is empty" >&2
    return 1
  fi

  local cond1_found=0
  local cond2_found=0
  local cond3_found=0

  # Condition 1: 8-byte alignment check
  if echo "$func_body" | grep -E -q '\(boundary & 7u\) == 0|\(boundary & 7\)|boundary % 8 == 0'; then
    cond1_found=1
    echo "    - Condition 1 (8-byte alignment): FOUND"
  else
    echo "    - Condition 1 (8-byte alignment): MISSING"
  fi

  # Condition 2: Sled bounds check (wholly inside decoded NOP run)
  if echo "$func_body" | grep -E -q 'boundary \+ REPRO_HCR_LX_WINDOW_BYTES <= out->sled_end|<= out->sled_end'; then
    cond2_found=1
    echo "    - Condition 2 (within sled bounds): FOUND"
  else
    echo "    - Condition 2 (within sled bounds): MISSING"
  fi

  # Condition 3: Instruction boundary walk
  if echo "$func_body" | grep -E -q 'repro_hcr_lx_nop_length' && echo "$func_body" | grep -E -q 'offset \+= len'; then
    cond3_found=1
    echo "    - Condition 3 (instruction boundary walk): FOUND"
  else
    echo "    - Condition 3 (instruction boundary walk): MISSING"
  fi

  local code_conditions=$((cond1_found + cond2_found + cond3_found))
  echo "    - Code enforces $code_conditions of 3 admissibility conditions."

  if [[ $code_conditions -ne 3 ]]; then
    echo "ERROR: Provider predicate in $header_file does not enforce all 3 conditions (found $code_conditions)" >&2
    return 1
  fi

  # Verify all 5 named refusal codes and string mappings
  local refusals=(
    "absent-sled:REPRO_HCR_LX_REFUSED_ABSENT_SLED"
    "non-nop-sled:REPRO_HCR_LX_REFUSED_NON_NOP_SLED"
    "short-sled:REPRO_HCR_LX_REFUSED_SHORT_SLED"
    "misaligned-entry:REPRO_HCR_LX_REFUSED_MISALIGNED_ENTRY"
    "sled-window-not-instruction-boundary:REPRO_HCR_LX_REFUSED_WINDOW_NOT_INSTRUCTION_BOUNDARY"
  )

  for ref in "${refusals[@]}"; do
    local str="${ref%%:*}"
    local sym="${ref##*:}"
    if ! grep -q "$sym" "$header_file"; then
      echo "ERROR: Missing refusal constant $sym in $header_file" >&2
      return 1
    fi
    if ! grep -q "\"$str\"" "$header_file"; then
      echo "ERROR: Missing refusal string \"$str\" in $header_file" >&2
      return 1
    fi
    echo "    - Refusal $str ($sym): FOUND"
  done

  echo "  [Code] OK: All 3 conditions and all 5 refusals verified in code."
  return 0
}

verify_doc_admissibility_rule() {
  local doc_file="$1"
  echo "  [Doc §4.2/§4.3] Inspecting admissibility rule in $(basename "$doc_file")..."

  if [[ ! -f "$doc_file" ]]; then
    echo "ERROR: Doc file not found: $doc_file" >&2
    return 1
  fi

  # Anti-vacuity: Check §4.2 exists
  if ! grep -q "## 4. Trampoline encoding" "$doc_file" && ! grep -q "### 4.2 The rule this provider adopts" "$doc_file"; then
    echo "ERROR: Anti-vacuity failure: §4.2 not found in $doc_file" >&2
    return 1
  fi

  # Extract §4.2
  local sec42
  sec42="$(awk '/### 4.2 The rule this provider adopts/,/### 4.3 Functions that cannot be patched/' "$doc_file")"
  if [[ -z "$sec42" ]]; then
    echo "ERROR: Anti-vacuity failure: extracted §4.2 text is empty" >&2
    return 1
  fi

  local cond1_found=0
  local cond2_found=0
  local cond3_found=0

  if echo "$sec42" | grep -E -q '1\.\s+(is\s+)?8-byte aligned'; then
    cond1_found=1
    echo "    - Doc Condition 1 (8-byte aligned): FOUND"
  else
    echo "    - Doc Condition 1 (8-byte aligned): MISSING"
  fi

  if echo "$sec42" | grep -E -q '2\.\s+.*(wholly inside the NOP run|wholly as NOP instructions)'; then
    cond2_found=1
    echo "    - Doc Condition 2 (wholly inside NOP run): FOUND"
  else
    echo "    - Doc Condition 2 (wholly inside NOP run): MISSING"
  fi

  if echo "$sec42" | grep -E -q '3\.\s+.*instruction boundary of that decoded run'; then
    cond3_found=1
    echo "    - Doc Condition 3 (instruction boundary of decoded run): FOUND"
  else
    echo "    - Doc Condition 3 (instruction boundary of decoded run): MISSING"
  fi

  local doc_conditions=$((cond1_found + cond2_found + cond3_found))
  echo "    - Doc §4.2 specifies $doc_conditions admissibility conditions."

  if [[ $doc_conditions -ne 3 ]]; then
    echo "ERROR: Drift detected: doc §4.2 specifies $doc_conditions conditions, but provider implementation enforces 3 conditions" >&2
    return 1
  fi

  # Verify explicit rejection mention in §4.2
  if ! echo "$sec42" | grep -E -q 'Window normalisation rejected.*HX-S-7.*HX-OQ-2'; then
    echo "ERROR: §4.2 does not record window normalisation rejection with references HX-S-7 and HX-OQ-2" >&2
    return 1
  fi
  echo "    - §4.2 explicit normalisation rejection note: FOUND"

  # Extract §4.3 and check 5 refusals
  local sec43
  sec43="$(awk '/### 4.3 Functions that cannot be patched/,/### 4.4/' "$doc_file")"
  local refusals=("absent-sled" "non-nop-sled" "short-sled" "misaligned-entry" "sled-window-not-instruction-boundary")
  for ref in "${refusals[@]}"; do
    if ! echo "$sec43" | grep -q "\`$ref\`"; then
      echo "ERROR: §4.3 missing documented refusal \`$ref\`" >&2
      return 1
    fi
    echo "    - Doc §4.3 refusal \`$ref\`: FOUND"
  done

  echo "  [Doc §4.2/§4.3] OK: 3-condition rule and 5 refusals verified in spec."
  return 0
}

verify_doc_option3_decision() {
  local doc_file="$1"
  echo "  [Doc §6.1] Inspecting Option 3 normalisation decision in $(basename "$doc_file")..."

  if [[ ! -f "$doc_file" ]]; then
    echo "ERROR: Doc file not found: $doc_file" >&2
    return 1
  fi

  # Anti-vacuity: Check §6.1 exists
  if ! grep -q "### 6.1 Tier 1" "$doc_file"; then
    echo "ERROR: Anti-vacuity failure: §6.1 not found in $doc_file" >&2
    return 1
  fi

  local sec61
  sec61="$(awk '/### 6.1 Tier 1/,/### 6.2 Tier 2/' "$doc_file")"
  if [[ -z "$sec61" ]]; then
    echo "ERROR: Anti-vacuity failure: extracted §6.1 text is empty" >&2
    return 1
  fi

  # Anti-vacuity check: Assert §6.1 no longer describes the option as open / left for review
  if echo "$sec61" | grep -E -q 'left for review rather than adopted here|not implemented, recorded because it is the one that would make tier 1 sound'; then
    echo "ERROR: Anti-vacuity failure: §6.1 still describes Option 3 as left for review / open rather than decided and rejected" >&2
    return 1
  fi

  # Verify explicit decision, milestone, question, and date
  if ! echo "$sec61" | grep -E -q 'Decided and REJECTED|decisively REJECTED'; then
    echo "ERROR: §6.1 does not state Option 3 is REJECTED" >&2
    return 1
  fi
  if ! echo "$sec61" | grep -q "HX-S-7"; then
    echo "ERROR: §6.1 does not reference milestone HX-S-7" >&2
    return 1
  fi
  if ! echo "$sec61" | grep -q "HX-OQ-2"; then
    echo "ERROR: §6.1 does not reference open question HX-OQ-2" >&2
    return 1
  fi
  if ! echo "$sec61" | grep -q "2026-09-15"; then
    echo "ERROR: §6.1 does not record decision date 2026-09-15" >&2
    return 1
  fi
  echo "    - Decision: Decided and REJECTED (2026-09-15, HX-S-7 closing HX-OQ-2): VERIFIED"

  # Verify the 7 rationale points
  # 1. dlopen hazard
  if ! echo "$sec61" | grep -q "dlopen"; then
    echo "ERROR: §6.1 rationale missing dlopen hazard" >&2
    return 1
  fi
  echo "    - Rationale 1 (dlopen hazard): VERIFIED"

  # 2. Startup sweep cost / COW text pages
  if ! echo "$sec61" | grep -E -q 'startup|130,000|130,037' || ! echo "$sec61" | grep -E -q 'copy-on-write|COW'; then
    echo "ERROR: §6.1 rationale missing startup sweep / COW text pages cost" >&2
    return 1
  fi
  echo "    - Rationale 2 (startup sweep and COW text pages): VERIFIED"

  # 3. Clang + CET incompatibility
  if ! echo "$sec61" | grep -q "Clang" || ! echo "$sec61" | grep -q "CET" || ! echo "$sec61" | grep -q "maximal"; then
    echo "ERROR: §6.1 rationale missing Clang + CET maximal NOP incompatibility" >&2
    return 1
  fi
  echo "    - Rationale 3 (Clang + CET incompatibility): VERIFIED"

  # 4. Architectural irrelevance on AArch64
  if ! echo "$sec61" | grep -q "AArch64" || ! echo "$sec61" | grep -E -q '4-byte|4 bytes|B imm26'; then
    echo "ERROR: §6.1 rationale missing AArch64 architectural irrelevance" >&2
    return 1
  fi
  echo "    - Rationale 4 (AArch64 architectural irrelevance): VERIFIED"

  # 5. Set-wide atomicity
  if ! echo "$sec61" | grep -E -q 'Set-wide atomicity|set-wide atomicity'; then
    echo "ERROR: §6.1 rationale missing set-wide atomicity requirement" >&2
    return 1
  fi
  echo "    - Rationale 5 (set-wide atomicity): VERIFIED"

  # 6. Transient W^X / executable page protection hazard
  if ! echo "$sec61" | grep -E -q 'W\^X|MDWE|SELinux|PROT_EXEC'; then
    echo "ERROR: §6.1 rationale missing transient page protection / W^X / MDWE hazard" >&2
    return 1
  fi
  echo "    - Rationale 6 (transient W^X / page protection hazard): VERIFIED"

  # 7. Tier 2 sound / proven
  if ! echo "$sec61" | grep -E -q '120 processes|960 publications|0 of 24'; then
    echo "ERROR: §6.1 rationale missing Tier 2 proven measurement (120 processes / 960 publications)" >&2
    return 1
  fi
  echo "    - Rationale 7 (Tier 2 proven sound): VERIFIED"

  # Verify platform consequences
  # - Linux: Tier 1 restricted to single-threaded; Tier 2 required for multithreaded
  if ! echo "$sec61" | grep -q "Linux" || ! echo "$sec61" | grep -E -q '[Tt]ier 1.*single-threaded'; then
    echo "ERROR: §6.1 platform consequence for Linux missing (tier 1 single-threaded)" >&2
    return 1
  fi
  # - AArch64: 4-byte aligned, no normalisation needed
  if ! echo "$sec61" | grep -q "AArch64" || ! echo "$sec61" | grep -E -q '[Nn]o normalisation needed'; then
    echo "ERROR: §6.1 platform consequence for AArch64 missing" >&2
    return 1
  fi
  # - Windows: HX-W-0, thread suspension, Detours-style IP adjustment / rAlign
  if ! echo "$sec61" | grep -q "Windows" || ! echo "$sec61" | grep -E -q 'HX-W-0|rAlign'; then
    echo "ERROR: §6.1 platform consequence for Windows missing (HX-W-0 / rAlign)" >&2
    return 1
  fi
  # - Clang + CET: remains refused (sled-window-not-instruction-boundary)
  if ! echo "$sec61" | grep -q "Clang + CET" || ! echo "$sec61" | grep -q "sled-window-not-instruction-boundary"; then
    echo "ERROR: §6.1 platform consequence for Clang + CET missing (sled-window-not-instruction-boundary)" >&2
    return 1
  fi
  echo "    - Platform consequences (Linux, AArch64, Windows HX-W-0, Clang+CET): VERIFIED"

  # Also check Open Questions table entry in Linux-ELF-Provider.md
  if ! grep -q "closed by \`HX-S-7\`" "$doc_file"; then
    echo "ERROR: HLX-OQ-2 in Open Questions table of $doc_file is not marked closed by HX-S-7" >&2
    return 1
  fi
  echo "    - Open Questions table HLX-OQ-2 marked closed by HX-S-7: VERIFIED"

  echo "  [Doc §6.1] OK: Option 3 rejection, rationale, and platform consequences fully verified."
  return 0
}

verify_trampoline_mechanics_spec() {
  local doc_file="$1"
  echo "  [Trampoline Spec] Inspecting $(basename "$doc_file")..."

  if [[ ! -f "$doc_file" ]]; then
    echo "ERROR: Trampoline spec not found: $doc_file" >&2
    return 1
  fi

  # Check §1.5 mentions window normalisation rejected under HX-S-7 / HX-OQ-2
  if ! grep -E -q 'Window Normalisation Evaluated and Rejected.*HX-S-7' "$doc_file"; then
    echo "ERROR: §1.5 does not document rejection of window normalisation under HX-S-7" >&2
    return 1
  fi
  echo "    - §1.5 window normalisation rejection (HX-S-7): VERIFIED"

  # Check §3.4 discusses IP adjustment vs. window normalisation
  if ! grep -E -q 'Cross-Platform IP Adjustment vs. Window Normalisation' "$doc_file"; then
    echo "ERROR: §3.4 does not discuss cross-platform IP adjustment vs. window normalisation" >&2
    return 1
  fi
  echo "    - §3.4 cross-platform IP adjustment vs. window normalisation: VERIFIED"

  echo "  [Trampoline Spec] OK: Trampoline mechanics updates verified."
  return 0
}

# -----------------------------------------------------------------------------
# Control Arm: Verification Against Real Committed Files
# -----------------------------------------------------------------------------
echo "[1/3] Running Control Arm against committed tree..."

verify_code_predicate "$REAL_C_HEADER"
verify_doc_admissibility_rule "$REAL_LINUX_SPEC"
verify_doc_option3_decision "$REAL_LINUX_SPEC"
verify_trampoline_mechanics_spec "$REAL_TRAMPOLINE_SPEC"

echo "[1/3] Control Arm PASSED cleanly."

# -----------------------------------------------------------------------------
# Anti-vacuity Assertions Summary
# -----------------------------------------------------------------------------
echo "[2/3] Validating anti-vacuity invariants..."
# 1. Assert predicate was located and non-empty in C code (checked in verify_code_predicate)
# 2. Assert §4.2 rule was parsed to non-empty condition count == 3 (checked in verify_doc_admissibility_rule)
# 3. Assert §6.1 does not contain 'left for review' (checked in verify_doc_option3_decision)
echo "  [OK] Anti-vacuity invariants satisfied."

# -----------------------------------------------------------------------------
# Falsifier Arms (--include-falsifier)
# -----------------------------------------------------------------------------
if [[ $INCLUDE_FALSIFIER -eq 1 ]]; then
  echo "[3/3] Running Falsifier Arms..."

  # Falsifier Arm 1: Doc drift - mutate doc to claim 2 conditions
  echo "  -> Falsifier Arm 1: Mutating doc to claim 2 conditions..."
  MOCK_DOC_DRIFT="$WORK_DIR/Linux-ELF-Provider-drift.md"
  cp "$REAL_LINUX_SPEC" "$MOCK_DOC_DRIFT"

  # Change condition list in §4.2 to remove condition 3
  python3 -c "
with open('$MOCK_DOC_DRIFT', 'r') as f:
    content = f.read()

# Replace condition 3 with empty or strip it
target = '''3. begins at an instruction boundary of that decoded run.'''
replacement = ''''''
if target not in content:
    raise RuntimeError('Target string not found for Arm 1')
content = content.replace(target, replacement)

with open('$MOCK_DOC_DRIFT', 'w') as f:
    f.write(content)
"

  if verify_doc_admissibility_rule "$MOCK_DOC_DRIFT" 2>"$WORK_DIR/arm1_err.log"; then
    echo "ERROR: Falsifier Arm 1 FAILED: mutated doc with 2 conditions unexpectedly passed verification!" >&2
    exit 1
  fi
  if ! grep -q "Drift detected" "$WORK_DIR/arm1_err.log"; then
    echo "ERROR: Falsifier Arm 1 failed with unexpected message:" >&2
    cat "$WORK_DIR/arm1_err.log" >&2
    exit 1
  fi
  echo "    [OK] Falsifier Arm 1 correctly failed naming drift: $(cat "$WORK_DIR/arm1_err.log")"

  # Falsifier Arm 2: Code mutation - remove condition 1 (8-byte alignment) from code
  echo "  -> Falsifier Arm 2: Mutating C code to remove 8-byte alignment condition..."
  MOCK_CODE_DRIFT="$WORK_DIR/repro_hcr_linux_x86_64_drift.h"
  cp "$REAL_C_HEADER" "$MOCK_CODE_DRIFT"

  python3 -c "
with open('$MOCK_CODE_DRIFT', 'r') as f:
    content = f.read()

target = '''if ((boundary & 7u) == 0 &&'''
replacement = '''if (/* alignment removed */'''
if target not in content:
    raise RuntimeError('Target string not found for Arm 2')
content = content.replace(target, replacement)

with open('$MOCK_CODE_DRIFT', 'w') as f:
    f.write(content)
"

  if verify_code_predicate "$MOCK_CODE_DRIFT" 2>"$WORK_DIR/arm2_err.log"; then
    echo "ERROR: Falsifier Arm 2 FAILED: mutated code unexpectedly passed verification!" >&2
    exit 1
  fi
  if ! grep -E -q "does not enforce all 3 conditions|Condition 1.*MISSING" "$WORK_DIR/arm2_err.log"; then
    echo "ERROR: Falsifier Arm 2 failed with unexpected message:" >&2
    cat "$WORK_DIR/arm2_err.log" >&2
    exit 1
  fi
  echo "    [OK] Falsifier Arm 2 correctly failed naming missing condition: $(head -n 2 "$WORK_DIR/arm2_err.log")"

  # Falsifier Arm 3: Reverting §6.1 to 'left for review' causes anti-vacuity failure
  echo "  -> Falsifier Arm 3: Mutating doc §6.1 to revert to 'left for review'..."
  MOCK_DOC_VACUOUS="$WORK_DIR/Linux-ELF-Provider-vacuous.md"
  cp "$REAL_LINUX_SPEC" "$MOCK_DOC_VACUOUS"

  python3 -c "
with open('$MOCK_DOC_VACUOUS', 'r') as f:
    content = f.read()

target = '''Decided and REJECTED'''
replacement = '''left for review rather than adopted here'''
if target not in content:
    raise RuntimeError('Target string not found for Arm 3')
content = content.replace(target, replacement)

with open('$MOCK_DOC_VACUOUS', 'w') as f:
    f.write(content)
"

  if verify_doc_option3_decision "$MOCK_DOC_VACUOUS" 2>"$WORK_DIR/arm3_err.log"; then
    echo "ERROR: Falsifier Arm 3 FAILED: mutated doc with 'left for review' unexpectedly passed verification!" >&2
    exit 1
  fi
  if ! grep -q "Anti-vacuity failure" "$WORK_DIR/arm3_err.log"; then
    echo "ERROR: Falsifier Arm 3 failed with unexpected message:" >&2
    cat "$WORK_DIR/arm3_err.log" >&2
    exit 1
  fi
  echo "    [OK] Falsifier Arm 3 correctly caught anti-vacuity failure: $(cat "$WORK_DIR/arm3_err.log")"

  echo "[3/3] All Falsifier Arms passed and behaved as required."
else
  echo "[3/3] Falsifiers skipped (pass --include-falsifier to run them)."
fi

echo "=== ALL CHECKS PASSED: hx_s7_the_normalisation_decision_is_recorded_and_the_rule_matches_it ==="
exit 0

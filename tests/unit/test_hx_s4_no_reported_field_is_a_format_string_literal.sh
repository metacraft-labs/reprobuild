#!/usr/bin/env bash
# test_hx_s4_no_reported_field_is_a_format_string_literal.sh
#
# Automated Verification Gate 1 for Milestone HX-S-4:
# "No field a consumer could recompute may be a compile-time constant"
#
# References:
# - reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org:583-649
# - reprobuild-specs/HCR/Linux-ELF-Provider.md §11
# - reprobuild-specs/HCR-Linux-ELF-Provider.milestones.org:1173
#
# Operative rule (campaign-wide, binding Linux, macOS, and Windows):
# "No field a consumer could independently recompute may be emitted as a
# compile-time constant; and if the agent cannot compute the value, the value
# must be syntactically incapable of being mistaken for the real thing —
# above all not a well-formed digest."
#
# Gate type: unit
# Real components:
# - repro_hcr_agent.c reporting functions as committed
# - Nim reference agent runtime.nim / protocol.nim
# Mocks allowed: none
#
# Anti-vacuity:
# - Assert >= 8 reported fields found in repro_hcr_agent.c
# - Assert reporting functions located and non-empty
# - Assert Nim reference types and fields parsed
#
# Control arm:
# - Verifies correctly derived fields (publicationTier, symbolGeneration, entryAddress, sharedLibraryPositivePath) pass.
#
# Falsifier arms:
# - Arm 1: Re-baking sharedLibraryPositivePath:false into format string fails gate and names field.
# - Arm 2: Injecting fabricated digest literal fails Clause 2 check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_C="$REPO_ROOT/libs/repro_hcr_agent/c/repro_hcr_agent.c"
RUNTIME_NIM="$REPO_ROOT/libs/repro_hcr_agent/src/repro_hcr_agent/runtime.nim"
PROTOCOL_NIM="$REPO_ROOT/libs/repro_hcr_agent/src/repro_hcr_agent/protocol.nim"

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

echo "=== Gate 1: hx_s4_no_reported_field_is_a_format_string_literal ==="

python3 - "$AGENT_C" "$RUNTIME_NIM" "$PROTOCOL_NIM" "$INCLUDE_FALSIFIER" << 'EOF'
import sys
import re

agent_c_path = sys.argv[1]
runtime_nim_path = sys.argv[2]
protocol_nim_path = sys.argv[3]
include_falsifier = int(sys.argv[4])

with open(agent_c_path, "r", encoding="utf-8") as f:
    agent_c = f.read()

with open(runtime_nim_path, "r", encoding="utf-8") as f:
    runtime_nim = f.read()

with open(protocol_nim_path, "r", encoding="utf-8") as f:
    protocol_nim = f.read()

# -----------------------------------------------------------------------------
# 1. Parse Nim Reference Types & Fields
# -----------------------------------------------------------------------------
print("[1/4] Parsing Nim reference types and fields from protocol.nim and runtime.nim...")
nim_types = ["HcrPatchApplied", "HcrCodePatchEvent", "HcrPatchFailed", "HcrHello"]
nim_fields = {}

for t in nim_types:
    m = re.search(rf"\b{t}\*\s*=\s*object(.*?)(?=\n\s*[A-Z]|\n\s*proc\b|\n\s*func\b|\Z)", protocol_nim, re.DOTALL)
    if not m:
        sys.stderr.write(f"ERROR: Failed to find Nim object type {t} in {protocol_nim_path}\n")
        sys.exit(1)
    fields = {}
    for line in m.group(1).splitlines():
        fm = re.match(r"^\s*([a-zA-Z0-9_]+)\*?:\s*([a-zA-Z0-9_\[\]]+)", line)
        if fm:
            fields[fm.group(1)] = fm.group(2)
    nim_fields[t] = fields
    print(f"  - {t}: found {len(fields)} fields: {', '.join(fields.keys())}")

# Collect set of all reference field names
reference_field_set = set()
for t, flds in nim_fields.items():
    reference_field_set.update(flds.keys())

if len(reference_field_set) < 10:
    sys.stderr.write(f"ERROR: Anti-vacuity failure: Expected >= 10 reference fields, found {len(reference_field_set)}\n")
    sys.exit(1)

# -----------------------------------------------------------------------------
# 2. Extract C Agent Reporting Functions
# -----------------------------------------------------------------------------
print("\n[2/4] Parsing C agent reporting functions from repro_hcr_agent.c...")

reporting_functions = [
    "repro_hcr_patch_applied_json",
    "repro_hcr_patch_failed_json",
    "repro_hcr_code_patch_json_fragment",
    "repro_hcr_hello_json",
    "repro_hcr_lifecycle_json",
    "repro_hcr_source_reload_result_json",
]

def extract_functions(c_source):
    extracted = {}
    for func in reporting_functions:
        pattern = rf"^static\s+(?:const\s+)?(?:char\s*\*|[a-z_0-9]+\s+){func}\b[^{{]*\{{(.*?)\n\}}"
        m = re.search(pattern, c_source, re.MULTILINE | re.DOTALL)
        if not m:
            sys.stderr.write(f"ERROR: Reporting function {func} was not found in C agent source!\n")
            sys.exit(1)
        body = m.group(1)
        if len(body.strip()) == 0:
            sys.stderr.write(f"ERROR: Reporting function {func} is empty!\n")
            sys.exit(1)
        extracted[func] = body
    return extracted

parsed_funcs = extract_functions(agent_c)
print(f"  Located {len(parsed_funcs)}/{len(reporting_functions)} reporting functions.")

# -----------------------------------------------------------------------------
# 3. Check Fields & Clause 2 on a given C AST/content
# -----------------------------------------------------------------------------
def run_audit(c_source, verbose=True):
    funcs = extract_functions(c_source)
    violations = []
    digest_violations = []
    found_fields = {}

    # Justified exemption list:
    # 1. `oldCodeRetained`: owned by HLX-M3 (see reprobuild-specs/HCR-Linux-ELF-Provider.milestones.org:1173
    #    and reprobuild-specs/HCR/Linux-ELF-Provider.md §11). Retained as literal true until HLX-M3 lands.
    # 2. `sourceGenerationMapDigest`: distinct non-digest tag ("unavailable:...") explicitly required by Clause 2
    #    until the C agent parses source generation maps.
    # 3. `stage`: lifecycle stage identifier in patchFailed JSON.
    EXEMPTIONS = {
        "oldCodeRetained": "Owned by HLX-M3 (see repro_hcr_agent.c:1879, HCR-Linux-ELF-Provider.milestones.org:1173)",
        "sourceGenerationMapDigest": "Distinct non-digest tag ('unavailable:...') explicitly permitted by Clause 2",
        "stage": "Lifecycle stage identifier in patchFailed response",
    }

    # Format specifiers that indicate dynamic parameterization
    FORMAT_SPECIFIER_REGEX = re.compile(r"%(?:[0-9]*\.?[0-9]*)?(?:[lhjztL]|ll)?[diuoxXfFeEgGaAcspn%]")

    # Clause 2: Check for fabricated digest literals
    # Any digest-shaped literal (<algo>-<bits>:<hex> or <algo>:<hex>) that is not the output of a hash call
    # or a distinct non-digest tag like "unavailable:...".
    FABRICATED_DIGEST_REGEX = re.compile(
        r"""(?:sha256|blake3|sha1|md5|sha512)(?:-[0-9]+)?:\s*(?:[0-9a-fA-F]{16,}|c-agent-[a-zA-Z0-9_-]+)"""
    )

    for fname, body in funcs.items():
        # Remove comments so comments describing defects or history aren't mistaken for code
        clean_body = re.sub(r"/\*.*?\*/", "", body, flags=re.DOTALL)
        clean_body = re.sub(r"//.*", "", clean_body)

        # Clause 2 check across all string literals in the reporting function
        for str_match in re.finditer(r'"([^"\\]*(?:\\.[^"\\]*)*)"', clean_body):
            s_val = str_match.group(1)
            # Check for fabricated digest
            for dig in FABRICATED_DIGEST_REGEX.finditer(s_val):
                digest_violations.append((fname, dig.group(0)))

        # Concatenate adjacent C string literals
        clean_body = re.sub(r'"\s*"', "", clean_body)

        # Extract JSON key-value pairs: \"key\": value
        field_matches = re.finditer(r'\\"([a-zA-Z0-9_]+)\\":\s*(\\"[^"]*\\"|\[[^\]]*\]|[^,}\\]+)', clean_body)
        for fm in field_matches:
            k = fm.group(1)
            v = fm.group(2).strip()

            # Skip JSON object containers like "codePatchEvent": {
            if v == "{" or v.startswith("{"):
                continue

            found_fields[k] = (fname, v)

            if k in EXEMPTIONS:
                if verbose:
                    print(f"  - Field '{k}' in {fname}: EXEMPT ({EXEMPTIONS[k]})")
                continue

            # If the field exists in the Nim reference implementation
            if k in reference_field_set:
                # Check for format specifiers and hardcoded constants
                is_hardcoded_bool = bool(re.match(r"^(?:true|false)", v))
                is_hardcoded_number = bool(re.match(r"^[0-9]+(?![a-zA-Z%])", v))
                has_specifier = bool(FORMAT_SPECIFIER_REGEX.search(v))
                is_fixed_literal_str = (
                    v.startswith('\\"') and v.endswith('\\"') and
                    not FORMAT_SPECIFIER_REGEX.search(v) and
                    not v[2:-2].startswith("unavailable:")
                )

                if is_hardcoded_bool or is_hardcoded_number or is_fixed_literal_str or not has_specifier:
                    violations.append((fname, k, v))
                elif verbose:
                    print(f"  - Field '{k}' in {fname}: dynamic format specifier validated (value: {v})")

    return violations, digest_violations, found_fields

print("\n[3/4] Validating field format specifiers and checking Clause 2...")
violations, digest_violations, found_fields = run_audit(agent_c, verbose=True)

if violations:
    sys.stderr.write("\nERROR: Violations found: reported fields are format-string constants:\n")
    for fname, k, v in violations:
        sys.stderr.write(f"  - Function {fname}: field '{k}' has constant value: '{v}'\n")
    sys.exit(1)

if digest_violations:
    sys.stderr.write("\nERROR: Clause 2 violations found: fabricated digest literals:\n")
    for fname, dig in digest_violations:
        sys.stderr.write(f"  - Function {fname}: fabricated digest literal '{dig}'\n")
    sys.exit(1)

# -----------------------------------------------------------------------------
# 4. Anti-vacuity & Control Arm
# -----------------------------------------------------------------------------
print("\n[4/4] Verifying anti-vacuity floors and control arm...")

# Anti-vacuity check: number of reported fields found in repro_hcr_agent.c >= 8
field_count = len(found_fields)
print(f"  - Total unique reported fields located: {field_count}")
if field_count < 8:
    sys.stderr.write(f"ERROR: Anti-vacuity failure: Expected >= 8 reported fields, found {field_count}\n")
    sys.exit(1)
print("  [OK] Anti-vacuity floor passed: >= 8 reported fields found.")

# Control arm: verify that correctly derived fields pass
CONTROL_FIELDS = ["publicationTier", "symbolGeneration", "entryAddress", "sharedLibraryPositivePath"]
for cf in CONTROL_FIELDS:
    if cf not in found_fields:
        sys.stderr.write(f"ERROR: Control arm failure: Expected control field '{cf}' not found in reported fields!\n")
        sys.exit(1)
    fname, val = found_fields[cf]
    print(f"  - Control field '{cf}' present in {fname} with format: {val}")

print("  [OK] Control arm passed: all required dynamically derived fields verified.")

# -----------------------------------------------------------------------------
# 5. Falsifiers
# -----------------------------------------------------------------------------
if include_falsifier:
    print("\n[FALSIFIER] Executing falsifier arms...")

    # Arm 1: Re-bake sharedLibraryPositivePath:false into format string
    print("  Testing Falsifier Arm 1: Re-baking sharedLibraryPositivePath:false...")
    mutated_c_1 = re.sub(
        r'(\\"sharedLibraryPositivePath\\":)%s',
        r'\g<1>false',
        agent_c
    )
    if mutated_c_1 == agent_c:
        sys.stderr.write("ERROR: Falsifier Arm 1 failed to mutate sharedLibraryPositivePath in C source!\n")
        sys.exit(1)

    arm1_violations, _, _ = run_audit(mutated_c_1, verbose=False)
    arm1_failed_field_names = [k for _, k, _ in arm1_violations]
    if "sharedLibraryPositivePath" not in arm1_failed_field_names:
        sys.stderr.write("ERROR: Falsifier Arm 1 FAILED: Re-baking sharedLibraryPositivePath:false was NOT rejected!\n")
        sys.exit(1)
    print(f"  [OK] Falsifier Arm 1 correctly went red naming field: 'sharedLibraryPositivePath'")

    # Arm 2: Inject fabricated digest literal
    print("  Testing Falsifier Arm 2: Injecting fabricated digest literal...")
    fabricated_digest = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    mutated_c_2 = re.sub(
        r'unavailable:\s*"\s*\n\s*"c-agent-does-not-parse-source-generation-map',
        fabricated_digest,
        agent_c
    )
    if mutated_c_2 == agent_c:
        mutated_c_2 = agent_c.replace(
            "unavailable:c-agent-does-not-parse-source-generation-map",
            fabricated_digest
        )
    if mutated_c_2 == agent_c:
        sys.stderr.write("ERROR: Falsifier Arm 2 failed to inject fabricated digest into C source!\n")
        sys.exit(1)

    _, arm2_digests, _ = run_audit(mutated_c_2, verbose=False)
    if not any(fabricated_digest in d for _, d in arm2_digests):
        sys.stderr.write(f"ERROR: Falsifier Arm 2 FAILED: Fabricated digest '{fabricated_digest}' was NOT caught!\n")
        sys.exit(1)
    print(f"  [OK] Falsifier Arm 2 correctly went red catching fabricated digest: '{fabricated_digest}'")

print("\n=== Gate 1 PASSED: hx_s4_no_reported_field_is_a_format_string_literal ===")
EOF

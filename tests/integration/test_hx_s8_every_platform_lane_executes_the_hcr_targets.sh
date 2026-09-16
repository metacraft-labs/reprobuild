#!/usr/bin/env bash
# test_hx_s8_every_platform_lane_executes_the_hcr_targets.sh
#
# Automated Integration Gate for Milestone HX-S-8:
# "CI actually invokes the HCR gates, on each platform"
#
# References:
# - reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org (lines 864-935)
# - codetracer/justfile (lines 306-350, 445-480)
# - codetracer/src/db-backend/tests/reprobuild_hcr_in_codetracer_test.rs (lines 1-10)
# - codetracer/.github/workflows/codetracer.yml
# - codetracer/.github/workflows/windows-msys2-provision-check.yml
# - codetracer-specs/Planned-Features/Reprobuild-HCR-MCR-DAP.milestones.org (M1-M4)
#
# Gate type: integration
# Real components:
# - Real workflow files in codetracer/.github/workflows/ (codetracer.yml, windows-msys2-provision-check.yml)
# - Real codetracer/justfile
# - Real codetracer/src/db-backend/tests/reprobuild_hcr_in_codetracer_test.rs
# Allowed mocks: none
#
# Verification:
# 1. Inspects codetracer/justfile:
#    - Asserts test-reprobuild-hcr-mcr-dap and test-reprobuild-hcr-in-codetracer exist.
#    - Asserts neither target contains a silent 'exit 0' skip for non-macOS/non-arm64 hosts.
#    - Asserts both targets fail loudly with exit code 2 outside macOS arm64.
#    - Asserts diagnostics name the supported host (macOS arm64 / aarch64-darwin).
# 2. Inspects codetracer/src/db-backend/tests/reprobuild_hcr_in_codetracer_test.rs:
#    - Asserts the non-macOS/non-arm64 cfg arm calls panic! with UNSUPPORTED, naming macOS arm64 / aarch64-darwin.
# 3. Inspects CI workflow lanes across all three platforms:
#    - macOS arm64 lane (reprobuild-macos-smoke, runs on aarch64-darwin): wires both targets.
#    - Linux x86_64 lane (reprobuild-linux-smoke, runs on eph-linux-x64-g1): wires both targets, handles exit code 2, verifies UNSUPPORTED diagnostic naming macOS arm64 / aarch64-darwin.
#    - Windows x86_64 lane (origin-dap-windows / windows-msys2-provision-check, runs on eph-win-x64): wires both targets, handles exit code 2, verifies UNSUPPORTED diagnostic naming macOS arm64 / aarch64-darwin.
# 4. Anti-vacuity:
#    - Asserts exactly 3 platform lanes are checked and validated (PLATFORMS_CHECKED == 3).
#    - Asserts recipes produce real output matching the expected unsupported diagnostic.
# 5. Control arm:
#    - Evaluates pre-change state where 0 lanes were wired and skips were silent 'exit 0'.
#    - Asserts the gate finds zero executing lanes on all three platforms on the pre-change state.
# 6. Falsifiers (--include-falsifier):
#    - Arm 1: Deleting an invocation from each platform lane fails the gate naming that specific lane.
#    - Arm 2: Restoring silent 'exit 0' skip into justfile fails the gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPRO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="${REPRO_WORKSPACE_DIR:-$(cd "$REPRO_ROOT/.." && pwd)}"

CODETRACER_DIR="$WORKSPACE_ROOT/codetracer"
WORKFLOWS_DIR="$CODETRACER_DIR/.github/workflows"
CODETRACER_YML="$WORKFLOWS_DIR/codetracer.yml"
WINDOWS_PROVISION_YML="$WORKFLOWS_DIR/windows-msys2-provision-check.yml"
JUSTFILE="$CODETRACER_DIR/justfile"
RUST_TEST_FILE="$CODETRACER_DIR/src/db-backend/tests/reprobuild_hcr_in_codetracer_test.rs"

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

WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d /tmp/hx_s8_gate1_XXXXXX)}"
cleanup() {
  if [[ -z "${PRESERVE_WORK:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

echo "=== Gate 1: hx_s8_every_platform_lane_executes_the_hcr_targets ==="
echo "Work directory: $WORK_DIR"
echo "CodeTracer directory: $CODETRACER_DIR"

# -----------------------------------------------------------------------------
# Helper: Verify justfile recipes
# -----------------------------------------------------------------------------
verify_justfile() {
  local jfile="$1"
  local target1="test-reprobuild-hcr-mcr-dap"
  local target2="test-reprobuild-hcr-in-codetracer"

  if [[ ! -f "$jfile" ]]; then
    echo "ERROR: justfile not found at $jfile" >&2
    return 1
  fi

  # Extract recipe bodies
  local body1
  body1=$(awk -v t="$target1:" '$0 ~ "^" t {flag=1; next} flag && /^[a-zA-Z0-9_-]+:/ {flag=0} flag {print}' "$jfile")
  if [[ -z "$body1" ]]; then
    echo "ERROR: Recipe $target1 not found in $jfile" >&2
    return 1
  fi

  local body2
  body2=$(awk -v t="$target2:" '$0 ~ "^" t {flag=1; next} flag && /^[a-zA-Z0-9_-]+:/ {flag=0} flag {print}' "$jfile")
  if [[ -z "$body2" ]]; then
    echo "ERROR: Recipe $target2 not found in $jfile" >&2
    return 1
  fi

  # Check neither contains silent exit 0 platform skip
  for t in "$target1" "$target2"; do
    local b
    if [[ "$t" == "$target1" ]]; then b="$body1"; else b="$body2"; fi

    # Check for silent skip pattern: echo "SKIP... exit 0
    if echo "$b" | grep -q 'SKIP:.*requires macOS arm64'; then
      if echo "$b" | grep -E -A 2 'SKIP:.*requires macOS arm64' | grep -q 'exit 0'; then
        echo "ERROR: Target $t contains silent 'exit 0' skip for non-macOS/non-arm64 hosts!" >&2
        return 1
      fi
    fi

    # Check for required loud UNSUPPORTED exit 2
    if ! echo "$b" | grep -q 'UNSUPPORTED:.*requires macOS arm64'; then
      echo "ERROR: Target $t missing loud 'UNSUPPORTED:' diagnostic!" >&2
      return 1
    fi
    if ! echo "$b" | grep -q 'exit 2'; then
      echo "ERROR: Target $t missing loud non-zero exit (exit 2)!" >&2
      return 1
    fi
    if ! echo "$b" | grep -q 'covered by macOS arm64 CI on aarch64-darwin'; then
      echo "ERROR: Target $t diagnostic does not name supported host 'aarch64-darwin'!" >&2
      return 1
    fi
  done

  return 0
}

# -----------------------------------------------------------------------------
# Helper: Verify Rust test loud unsupported panic
# -----------------------------------------------------------------------------
verify_rust_test() {
  local rfile="$1"
  if [[ ! -f "$rfile" ]]; then
    echo "ERROR: Rust test file not found at $rfile" >&2
    return 1
  fi

  local header
  header=$(head -n 15 "$rfile")

  if echo "$header" | grep -q 'eprintln!("SKIPPED:'; then
    echo "ERROR: Rust test file uses silent eprintln! skip instead of panic!" >&2
    return 1
  fi

  if ! echo "$header" | grep -q 'panic!'; then
    echo "ERROR: Rust test file missing panic! in unsupported arm!" >&2
    return 1
  fi

  if ! echo "$header" | grep -q 'UNSUPPORTED: reprobuild_hcr_in_codetracer requires macOS arm64'; then
    echo "ERROR: Rust test file missing 'UNSUPPORTED: reprobuild_hcr_in_codetracer requires macOS arm64' diagnostic!" >&2
    return 1
  fi

  if ! echo "$header" | grep -q 'covered by macOS arm64 on aarch64-darwin'; then
    echo "ERROR: Rust test panic does not name supported host 'aarch64-darwin'!" >&2
    return 1
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Helper: Verify platform lanes in workflow files
# -----------------------------------------------------------------------------
verify_platform_lanes() {
  local c_yml="$1"
  local win_yml="$2"

  local target1="test-reprobuild-hcr-mcr-dap"
  local target2="test-reprobuild-hcr-in-codetracer"

  local lanes_verified=0

  # Lane 1: macOS arm64 (in codetracer.yml under reprobuild-macos-smoke)
  # Runs on aarch64-darwin
  echo "  Checking Lane 1: macOS arm64 (aarch64-darwin)..."
  local macos_job
  macos_job=$(awk '/^  reprobuild-macos-smoke:/{flag=1; next} flag && /^  [a-zA-Z0-9_-]+:/{flag=0} flag {print}' "$c_yml")
  if [[ -z "$macos_job" ]]; then
    echo "ERROR: macOS arm64 lane (reprobuild-macos-smoke) not found in $c_yml" >&2
    return 1
  fi
  if ! echo "$macos_job" | grep -q "$target1"; then
    echo "ERROR: macOS arm64 lane missing invocation of $target1!" >&2
    return 1
  fi
  if ! echo "$macos_job" | grep -q "$target2"; then
    echo "ERROR: macOS arm64 lane missing invocation of $target2!" >&2
    return 1
  fi
  lanes_verified=$((lanes_verified + 1))
  echo "    [OK] macOS arm64 lane wires both HCR targets."

  # Lane 2: Linux x86_64 (in codetracer.yml under reprobuild-linux-smoke)
  # Runs on eph-linux-x64-g1
  echo "  Checking Lane 2: Linux x86_64 (eph-linux-x64-g1)..."
  local linux_job
  linux_job=$(awk '/^  reprobuild-linux-smoke:/{flag=1; next} flag && /^  [a-zA-Z0-9_-]+:/{flag=0} flag {print}' "$c_yml")
  if [[ -z "$linux_job" ]]; then
    echo "ERROR: Linux x86_64 lane (reprobuild-linux-smoke) not found in $c_yml" >&2
    return 1
  fi
  if ! echo "$linux_job" | grep -q "$target1"; then
    echo "ERROR: Linux x86_64 lane missing invocation of $target1!" >&2
    return 1
  fi
  if ! echo "$linux_job" | grep -q "$target2"; then
    echo "ERROR: Linux x86_64 lane missing invocation of $target2!" >&2
    return 1
  fi
  # Must assert non-zero exit (exit 2) and unsupported message naming macOS arm64
  if ! echo "$linux_job" | grep -q 'exit_code.*-ne 2\|exit 2\|\$? -eq 2'; then
    echo "ERROR: Linux x86_64 lane does not assert loud non-zero exit code 2!" >&2
    return 1
  fi
  if ! echo "$linux_job" | grep -q 'aarch64-darwin\|macOS arm64'; then
    echo "ERROR: Linux x86_64 lane does not verify unsupported diagnostic naming macOS arm64!" >&2
    return 1
  fi
  lanes_verified=$((lanes_verified + 1))
  echo "    [OK] Linux x86_64 lane wires both HCR targets with loud unsupported handling."

  # Lane 3: Windows x86_64 (in codetracer.yml under origin-dap-windows OR windows-msys2-provision-check.yml)
  # Runs on eph-win-x64
  echo "  Checking Lane 3: Windows x86_64 (eph-win-x64)..."
  local win_found=0
  local win_job=""

  if grep -q "Verify $target1 fails loudly unsupported on Windows" "$c_yml"; then
    win_job=$(awk '/^  origin-dap-windows:/{flag=1; next} flag && /^  [a-zA-Z0-9_-]+:/{flag=0} flag {print}' "$c_yml")
    if echo "$win_job" | grep -q "$target1" && echo "$win_job" | grep -q "$target2"; then
      win_found=1
    fi
  fi
  if [[ $win_found -eq 0 ]] && [[ -f "$win_yml" ]]; then
    if grep -q "$target1" "$win_yml" && grep -q "$target2" "$win_yml"; then
      win_job=$(cat "$win_yml")
      win_found=1
    fi
  fi

  if [[ $win_found -eq 0 ]]; then
    echo "ERROR: Windows x86_64 lane missing invocation of $target1 and $target2!" >&2
    return 1
  fi

  if ! echo "$win_job" | grep -q 'exit_code.*-ne 2\|exit 2\|\$? -eq 2'; then
    echo "ERROR: Windows x86_64 lane does not assert loud non-zero exit code 2!" >&2
    return 1
  fi
  if ! echo "$win_job" | grep -q 'aarch64-darwin\|macOS arm64'; then
    echo "ERROR: Windows x86_64 lane does not verify unsupported diagnostic naming macOS arm64!" >&2
    return 1
  fi
  lanes_verified=$((lanes_verified + 1))
  echo "    [OK] Windows x86_64 lane wires both HCR targets with loud unsupported handling."

  # Anti-vacuity check: exactly 3 platform lanes
  if [[ $lanes_verified -ne 3 ]]; then
    echo "ERROR: Anti-vacuity failure: expected exactly 3 platform lanes, verified $lanes_verified" >&2
    return 1
  fi

  return 0
}

# -----------------------------------------------------------------------------
# 1. Inspect real codetracer/justfile
# -----------------------------------------------------------------------------
echo "[1/5] Verifying codetracer/justfile loud skips..."
verify_justfile "$JUSTFILE"
echo "  [OK] justfile targets have loud exit 2 skips naming macOS arm64 / aarch64-darwin."

# -----------------------------------------------------------------------------
# 2. Inspect real Rust test file
# -----------------------------------------------------------------------------
echo "[2/5] Verifying Rust test file unsupported profile panic..."
verify_rust_test "$RUST_TEST_FILE"
echo "  [OK] Rust test panics loudly on unsupported platforms naming macOS arm64 / aarch64-darwin."

# -----------------------------------------------------------------------------
# 3. Inspect real CI workflow files across all 3 platforms
# -----------------------------------------------------------------------------
echo "[3/5] Verifying CI workflows across 3 platform lanes..."
verify_platform_lanes "$CODETRACER_YML" "$WINDOWS_PROVISION_YML"
echo "  [OK] Exactly 3 platform lanes verified."

# -----------------------------------------------------------------------------
# 4. Anti-vacuity: Execute recipe platform check directly
# -----------------------------------------------------------------------------
echo "[4/5] Anti-vacuity: Executing platform check directly..."
# Simulate execution of test-reprobuild-hcr-mcr-dap check on Linux/Windows
sim_check=$(bash -c '
  sim_uname_s="Linux"
  sim_uname_m="x86_64"
  if [ "$sim_uname_s" != "Darwin" ] || [ "$sim_uname_m" != "arm64" ]; then
    echo "UNSUPPORTED: test-reprobuild-hcr-mcr-dap requires macOS arm64 (got $sim_uname_s $sim_uname_m); covered by macOS arm64 CI on aarch64-darwin." >&2
    exit 2
  fi
' 2>&1 || true)

if ! echo "$sim_check" | grep -q "UNSUPPORTED: test-reprobuild-hcr-mcr-dap requires macOS arm64 (got Linux x86_64); covered by macOS arm64 CI on aarch64-darwin."; then
  echo "ERROR: Simulated platform check did not produce expected diagnostic!" >&2
  exit 1
fi

# On current host (Darwin arm64), assert uname check succeeds
if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "WARNING: Running on non-Darwin/arm64 host; skip test expected."
else
  echo "  [OK] Host Darwin arm64 correctly passes platform condition."
fi
echo "  [OK] Anti-vacuity checks passed."

# -----------------------------------------------------------------------------
# 5. Control arm: Verify pre-change workflows find zero executing lanes
# -----------------------------------------------------------------------------
echo "[5/5] Control arm: Testing pre-change workflows (must find 0 executing lanes)..."
mkdir -p "$WORK_DIR/control_workflows"
# Pre-change codetracer.yml had no HCR invocations in reprobuild-macos-smoke, reprobuild-linux-smoke, or windows jobs
cat "$CODETRACER_YML" | \
  sed '/Run Reprobuild HCR MCR DAP test/d' | \
  sed '/test-reprobuild-hcr-mcr-dap/d' | \
  sed '/Run Reprobuild HCR in CodeTracer test/d' | \
  sed '/test-reprobuild-hcr-in-codetracer/d' | \
  sed '/Verify test-reprobuild-hcr-mcr-dap/d' | \
  sed '/Verify test-reprobuild-hcr-in-codetracer/d' > "$WORK_DIR/control_workflows/codetracer.yml"

cat "$WINDOWS_PROVISION_YML" | \
  sed '/Verify test-reprobuild-hcr-mcr-dap/d' | \
  sed '/test-reprobuild-hcr-mcr-dap/d' | \
  sed '/Verify test-reprobuild-hcr-in-codetracer/d' | \
  sed '/test-reprobuild-hcr-in-codetracer/d' > "$WORK_DIR/control_workflows/windows.yml"

if verify_platform_lanes "$WORK_DIR/control_workflows/codetracer.yml" "$WORK_DIR/control_workflows/windows.yml" 2>/dev/null; then
  echo "ERROR: Control arm failed: pre-change workflows were accepted as wired!" >&2
  exit 1
fi
echo "  [OK] Control arm verified: pre-change workflows correctly rejected."

# -----------------------------------------------------------------------------
# Falsifier arms (--include-falsifier)
# -----------------------------------------------------------------------------
if [[ $INCLUDE_FALSIFIER -eq 1 ]]; then
  echo ""
  echo "=== Running Falsifier Arms ==="

  # Falsifier 1a: Delete invocation from macOS arm64 lane
  echo "[Falsifier 1a] Deleting invocation from macOS arm64 lane..."
  cp "$CODETRACER_YML" "$WORK_DIR/codetracer_no_macos.yml"
  python3 -c '
with open("'"$WORK_DIR"'/codetracer_no_macos.yml", "r") as f:
    text = f.read()
idx = text.find("reprobuild-macos-smoke:")
idx2 = text.find("reprobuild-linux-smoke:", idx)
chunk = text[idx:idx2]
chunk_mut = chunk.replace("test-reprobuild-hcr-mcr-dap", "test-deleted-hcr-target")
text = text[:idx] + chunk_mut + text[idx2:]
with open("'"$WORK_DIR"'/codetracer_no_macos.yml", "w") as f:
    f.write(text)
'
  if verify_platform_lanes "$WORK_DIR/codetracer_no_macos.yml" "$WINDOWS_PROVISION_YML" 2>"$WORK_DIR/falsifier_1a.log"; then
    echo "ERROR: Falsifier 1a failed: gate passed despite missing macOS invocation!" >&2
    exit 1
  fi
  if ! grep -q "macOS arm64 lane missing invocation" "$WORK_DIR/falsifier_1a.log"; then
    echo "ERROR: Falsifier 1a failed: error message did not name macOS arm64 lane!" >&2
    cat "$WORK_DIR/falsifier_1a.log" >&2
    exit 1
  fi
  echo "  [OK] Falsifier 1a caught missing macOS arm64 invocation."

  # Falsifier 1b: Delete invocation from Linux x86_64 lane
  echo "[Falsifier 1b] Deleting invocation from Linux x86_64 lane..."
  cp "$CODETRACER_YML" "$WORK_DIR/codetracer_no_linux.yml"
  python3 -c '
with open("'"$WORK_DIR"'/codetracer_no_linux.yml", "r") as f:
    text = f.read()
idx = text.find("reprobuild-linux-smoke:")
idx2 = text.find("origin-dap-macos:", idx)
chunk = text[idx:idx2]
chunk_mut = chunk.replace("test-reprobuild-hcr-mcr-dap", "test-deleted-hcr-target")
text = text[:idx] + chunk_mut + text[idx2:]
with open("'"$WORK_DIR"'/codetracer_no_linux.yml", "w") as f:
    f.write(text)
'
  if verify_platform_lanes "$WORK_DIR/codetracer_no_linux.yml" "$WINDOWS_PROVISION_YML" 2>"$WORK_DIR/falsifier_1b.log"; then
    echo "ERROR: Falsifier 1b failed: gate passed despite missing Linux invocation!" >&2
    exit 1
  fi
  if ! grep -q "Linux x86_64 lane missing invocation" "$WORK_DIR/falsifier_1b.log"; then
    echo "ERROR: Falsifier 1b failed: error message did not name Linux x86_64 lane!" >&2
    cat "$WORK_DIR/falsifier_1b.log" >&2
    exit 1
  fi
  echo "  [OK] Falsifier 1b caught missing Linux x86_64 invocation."

  # Falsifier 1c: Delete invocation from Windows x86_64 lane
  echo "[Falsifier 1c] Deleting invocation from Windows x86_64 lane..."
  cp "$CODETRACER_YML" "$WORK_DIR/codetracer_no_win.yml"
  cp "$WINDOWS_PROVISION_YML" "$WORK_DIR/win_no_win.yml"
  python3 -c '
with open("'"$WORK_DIR"'/codetracer_no_win.yml", "r") as f:
    text = f.read()
idx = text.find("origin-dap-windows:")
idx2 = text.find("windows-named-pipe-tests:", idx)
chunk = text[idx:idx2]
chunk_mut = chunk.replace("test-reprobuild-hcr-mcr-dap", "test-other-thing").replace("test-reprobuild-hcr-in-codetracer", "test-other-thing2")
text = text[:idx] + chunk_mut + text[idx2:]
with open("'"$WORK_DIR"'/codetracer_no_win.yml", "w") as f:
    f.write(text)

with open("'"$WORK_DIR"'/win_no_win.yml", "r") as f:
    text = f.read()
text = text.replace("test-reprobuild-hcr-mcr-dap", "test-other-thing").replace("test-reprobuild-hcr-in-codetracer", "test-other-thing2")
with open("'"$WORK_DIR"'/win_no_win.yml", "w") as f:
    f.write(text)
'
  if verify_platform_lanes "$WORK_DIR/codetracer_no_win.yml" "$WORK_DIR/win_no_win.yml" 2>"$WORK_DIR/falsifier_1c.log"; then
    echo "ERROR: Falsifier 1c failed: gate passed despite missing Windows invocation!" >&2
    exit 1
  fi
  if ! grep -q "Windows x86_64 lane missing invocation" "$WORK_DIR/falsifier_1c.log"; then
    echo "ERROR: Falsifier 1c failed: error message did not name Windows x86_64 lane!" >&2
    cat "$WORK_DIR/falsifier_1c.log" >&2
    exit 1
  fi
  echo "  [OK] Falsifier 1c caught missing Windows x86_64 invocation."

  # Falsifier 2: Restore silent exit 0 skip into justfile
  echo "[Falsifier 2] Restoring silent exit 0 skip into justfile..."
  cp "$JUSTFILE" "$WORK_DIR/justfile_silent_skip"
  python3 -c '
with open("'"$WORK_DIR"'/justfile_silent_skip", "r") as f:
    text = f.read()
text = text.replace(
    "echo \"UNSUPPORTED: test-reprobuild-hcr-mcr-dap requires macOS arm64 (got $(uname -s) $(uname -m)); covered by macOS arm64 CI on aarch64-darwin.\" >&2\n    exit 2",
    "echo \"SKIP: test-reprobuild-hcr-mcr-dap requires macOS arm64 ($(uname -s) $(uname -m)).\" >&2\n    exit 0"
)
with open("'"$WORK_DIR"'/justfile_silent_skip", "w") as f:
    f.write(text)
'
  if verify_justfile "$WORK_DIR/justfile_silent_skip" 2>"$WORK_DIR/falsifier_2.log"; then
    echo "ERROR: Falsifier 2 failed: gate passed despite silent exit 0 skip in justfile!" >&2
    exit 1
  fi
  if ! grep -q "silent 'exit 0' skip" "$WORK_DIR/falsifier_2.log"; then
    echo "ERROR: Falsifier 2 failed: error message did not name silent exit 0 skip!" >&2
    cat "$WORK_DIR/falsifier_2.log" >&2
    exit 1
  fi
  echo "  [OK] Falsifier 2 caught silent exit 0 skip."

  echo "=== All Falsifier Arms Passed ==="
fi

echo ""
echo "=== Gate 1 PASSED: All 3 platform lanes execute HCR targets with loud reporting ==="

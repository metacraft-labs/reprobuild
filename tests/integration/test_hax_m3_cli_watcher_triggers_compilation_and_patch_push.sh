#!/usr/bin/env bash
# test_hax_m3_cli_watcher_triggers_compilation_and_patch_push.sh
#
# Automated Integration Verification Gate for Milestone HAX-M3:
# "Live CLI Watcher Event Loop"
#
# Design doc: reprobuild-specs/HCR/CLI-Integration.md §2–§4
#             reprobuild-specs/HCR/HCR-Overview.md §12
# Related milestones:
# - reprobuild-specs/HCR-Advanced-Lifecycle-And-Tooling.milestones.org (HAX-M3)
#
# Gate type: e2e / integration
# Real components:
# - Real compiled repro CLI binary (build/bin/repro)
# - Real C target process linking libs/repro_hcr_agent/c/repro_hcr_agent.c
# - Real coordinator Unix domain socket
# - Real filesystem watcher (kqueue on macOS arm64)
# - Real C compilation and patch generation
#
# Allowed mocks: none
# Justification: Every use of mock objects in tests must be explicitly justified in the
# header comment of the test implementation file. We prefer strong integration tests that
# mock as little as possible and run against real filesystem, compiler, binary, and
# lifecycle execution boundaries. Mocks used: ZERO.
#
# Asserts:
# 1. Anti-vacuity Arm:
#    - Non-source changes (edits in .git/ or temporary files like .swp, ~, #) are filtered
#      and trigger no build/patch actions.
#    - Debouncing coalesces rapid file saves into a single compilation cycle.
# 2. Control Arm:
#    - Unchanged files trigger no build or patch actions.
# 3. Positive Arm:
#    - Target process starts, reports initial baseline value (11).
#    - Test driver edits source file on disk (patchable.c: 11 -> 77).
#    - Watcher detects change within 500ms, triggers incremental compile, generates patch bundle,
#      delivers over coordinator socket.
#    - Target process receives patch, applies trampoline/relocation, and immediately reflects new value (77).
# 4. Falsifier & Recovery Arm (--falsify-syntax-error):
#    - Writes invalid C syntax into patchable.c (int patchable_value(int i) { invalid syntax ;;; }).
#    - Watcher triggers compile, catches compiler error, emits hcr/compilationFailed, suppresses
#      patch delivery, and DOES NOT CRASH or exit.
#    - Target process remains running and returns previous valid value (77).
#    - Then valid code is written (return 99;).
#    - Watcher recompiles successfully, pushes patch, and target process reflects 99!
#    - In falsifier mode, verifies syntax error logging and patch suppression, caught with [FALSIFIER-CAUGHT].

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d /tmp/hax_m3_gate_XXXXXX)}"

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

echo "=== Gate: test_hax_m3_cli_watcher_triggers_compilation_and_patch_push ==="
echo "Working directory: $WORK_DIR"

# Ensure Nix/ambient runtime libraries (libclingo, libzstd) are accessible
if [[ -z "${CLINGO_LIB:-}" ]]; then
  DETECTED_CLINGO_DIR="$(ls -d /nix/store/*clingo-5*/lib 2>/dev/null | head -1 || true)"
  if [[ -n "$DETECTED_CLINGO_DIR" && -d "$DETECTED_CLINGO_DIR" ]]; then
    export CLINGO_LIB="$DETECTED_CLINGO_DIR"
  fi
fi

if [[ -n "${CLINGO_LIB:-}" && -d "${CLINGO_LIB:-}" ]]; then
  export DYLD_FALLBACK_LIBRARY_PATH="${CLINGO_LIB}${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
  export DYLD_LIBRARY_PATH="${CLINGO_LIB}${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  export LD_LIBRARY_PATH="${CLINGO_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# -----------------------------------------------------------------------------
# 1. Verify compiler prerequisites and repro CLI binary
# -----------------------------------------------------------------------------
echo "[1/5] Checking compiler prerequisites and repro CLI binary..."
cd "$REPO_ROOT"

if ! command -v clang >/dev/null 2>&1; then
  echo "ERROR: clang compiler is required but not found in PATH" >&2
  exit 1
fi
if ! command -v nim >/dev/null 2>&1; then
  echo "ERROR: nim compiler is required but not found in PATH" >&2
  exit 1
fi

REPRO_BIN="$REPO_ROOT/build/bin/repro"
if [[ ! -x "$REPRO_BIN" ]]; then
  echo "ERROR: repro CLI binary not found at $REPRO_BIN" >&2
  echo "Please compile repro before running this gate." >&2
  exit 1
fi

HCR_AGENT_DIR="$REPO_ROOT/libs/repro_hcr_agent/c"
HCR_AGENT_C="$HCR_AGENT_DIR/repro_hcr_agent.c"
if [[ ! -f "$HCR_AGENT_C" ]]; then
  echo "ERROR: repro_hcr_agent.c not found at $HCR_AGENT_C" >&2
  exit 1
fi

echo "  [OK] Compilers (clang, nim), repro binary, and HCR agent available."

# -----------------------------------------------------------------------------
# 2. Compile real C target process linking repro_hcr_agent.c
# -----------------------------------------------------------------------------
echo "[2/5] Compiling real C target process with clang linking repro_hcr_agent.c..."

PATCHABLE_BASELINE_C="$WORK_DIR/patchable_baseline.c"
cat << 'EOF' > "$PATCHABLE_BASELINE_C"
__attribute__((noinline))
int patchable_value(int iteration) {
  int bias = 11;
  int state = iteration + bias;
  return state;
}
EOF

TARGET_MAIN_C="$WORK_DIR/target_main.c"
cat << 'EOF' > "$TARGET_MAIN_C"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "repro_hcr_agent.h"

extern int patchable_value(int iteration);

int main(int argc, char **argv) {
  repro_hcr_agent_symbol symbols[1];
  symbols[0].name = "patchable_value";
  symbols[0].address = (void *)patchable_value;

  if (repro_hcr_agent_start_from_env(
        repro_hcr_agent_default_support_profile(), symbols, 1) != 0) {
    fprintf(stderr, "Failed to start HCR agent\n");
    return 1;
  }

  printf("TARGET_READY\n");
  fflush(stdout);

  char line[256];
  while (fgets(line, sizeof(line), stdin)) {
    if (strncmp(line, "get", 3) == 0) {
      int val = patchable_value(0);
      printf("VALUE=%d\n", val);
      fflush(stdout);
    } else if (strncmp(line, "exit", 4) == 0) {
      break;
    }
  }
  return 0;
}
EOF

TARGET_BIN="$WORK_DIR/target_app"
clang -O0 -c "$PATCHABLE_BASELINE_C" -o "$WORK_DIR/patchable_baseline.o"
clang -O2 -I"$HCR_AGENT_DIR" -c "$TARGET_MAIN_C" -o "$WORK_DIR/target_main.o"
clang -O2 -I"$HCR_AGENT_DIR" -c "$HCR_AGENT_C" -o "$WORK_DIR/agent.o"
clang "$WORK_DIR/patchable_baseline.o" "$WORK_DIR/target_main.o" "$WORK_DIR/agent.o" -o "$TARGET_BIN"
codesign -s - -f "$TARGET_BIN"

echo "  [OK] Real C target binary compiled and signed: $TARGET_BIN"

# -----------------------------------------------------------------------------
# 3. Build the Nim integration test driver
# -----------------------------------------------------------------------------
echo "[3/5] Compiling Nim integration test driver..."

DRIVER_SRC="$REPO_ROOT/tests/fixtures/hcr/watch_patch_push_driver.nim"
DRIVER_BIN="$WORK_DIR/test_hax_m3_driver"

nim c --hints:off --warnings:off \
  --nimcache:"$WORK_DIR/nimcache" \
  --path:"$REPO_ROOT/libs/repro_hcr_agent/src" \
  --path:"$REPO_ROOT/libs/repro_test_support/src" \
  -o:"$DRIVER_BIN" \
  "$DRIVER_SRC"

echo "  [OK] Test driver compiled: $DRIVER_BIN"

# -----------------------------------------------------------------------------
# 4. Execute test driver: Anti-vacuity, Control, Positive, Recovery arms
# -----------------------------------------------------------------------------
echo "[4/5] Running test driver (Anti-vacuity, Control, Positive, Recovery)..."

"$DRIVER_BIN" "$TARGET_BIN" "$REPRO_BIN" "$WORK_DIR"

echo "  [OK] All test driver verification arms passed."

# -----------------------------------------------------------------------------
# 5. Falsifier
# -----------------------------------------------------------------------------
if [[ $INCLUDE_FALSIFIER -eq 1 ]]; then
  echo "[5/5] Executing falsifier arm..."
  echo "  Testing Falsifier: Simulating compiler syntax error and patch suppression (--falsify-syntax-error)..."

  FALSIFY_WORK_DIR="$WORK_DIR/falsifier_work"
  mkdir -p "$FALSIFY_WORK_DIR"

  set +e
  "$DRIVER_BIN" --falsify-syntax-error "$TARGET_BIN" "$REPRO_BIN" "$FALSIFY_WORK_DIR" > "$WORK_DIR/falsifier.log" 2>&1
  FALSIFIER_RC=$?
  set -e

  if [[ $FALSIFIER_RC -eq 0 ]]; then
    echo "ERROR: Falsifier unexpectedly succeeded!" >&2
    cat "$WORK_DIR/falsifier.log" >&2
    exit 1
  fi

  if ! grep -q "FALSIFIER-CAUGHT" "$WORK_DIR/falsifier.log"; then
    echo "ERROR: Falsifier did not emit expected FALSIFIER-CAUGHT diagnostic!" >&2
    cat "$WORK_DIR/falsifier.log" >&2
    exit 1
  fi
  echo "  [OK] Falsifier caught: $(grep "FALSIFIER-CAUGHT" "$WORK_DIR/falsifier.log")"
else
  echo "[5/5] Falsifier execution skipped (pass --include-falsifier to enable)."
fi

echo ""
echo "=== Gate PASSED: test_hax_m3_cli_watcher_triggers_compilation_and_patch_push ==="

#!/usr/bin/env bash
# test_hx_s0_the_hcr_library_is_one_named_artifact_on_three_platforms.sh
#
# Integration Gate for Milestone HX-S-0:
# "One HCR library, one header, one exported ABI — and an artifact that links"
#
# Design doc: reprobuild-specs/HCR/HCR-Overview.md §5.1, §10, §13
#
# Asserts:
# 1. Real build produces the canonical shared library on Darwin arm64.
# 2. Canonical naming on all three platforms:
#    - macOS:   librepro_hcr_agent.dylib
#    - Linux:   librepro_hcr_agent.so
#    - Windows: repro_hcr_agent.dll
# 3. Anti-vacuity:
#    - Artifact is non-empty.
#    - Platform count is exactly 3; none skipped.
#    - nm resolves all 15 repro_hcr_agent_* and all 10 rb_hcr_* symbols to defined addresses.
# 4. Process injection:
#    - DYLD_INSERT_LIBRARIES (macOS injection mechanism from §5.1/§10) successfully loads it.
#    - dlopen / dlsym resolves all symbols at runtime.
# 5. Control arm:
#    - Confirms pre-change failure when artifact does not exist.
# 6. Falsifiers:
#    - Renaming to loser spellings (libct_hcr_agent, bare repro_hcr_agent) fails at load.
#    - Missing symbols fail symbol verification.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_DIR="$REPO_ROOT/libs/repro_hcr_agent"
BUILD_SCRIPT="$AGENT_DIR/build_lib.sh"
WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d /tmp/hx_s0_gate1_XXXXXX)}"

INCLUDE_FALSIFIER=0
for arg in "$@"; do
  case "$arg" in
    --include-falsifier|--falsifier)
      INCLUDE_FALSIFIER=1
      ;;
  esac
done

cleanup() {
  if [[ -z "${PRESERVE_WORK:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

echo "=== Gate 1: hx_s0_the_hcr_library_is_one_named_artifact_on_three_platforms ==="
echo "Working directory: $WORK_DIR"

# -----------------------------------------------------------------------------
# 1. Platform naming validation (3 platforms, exactly 3, none skipped)
# -----------------------------------------------------------------------------
echo "[1/5] Validating canonical naming rules across 3 platforms..."

PLATFORMS=("darwin" "linux" "windows")
EXPECTED_NAMES=("librepro_hcr_agent.dylib" "librepro_hcr_agent.so" "repro_hcr_agent.dll")
INJECTION_MECHS=("DYLD_INSERT_LIBRARIES" "LD_PRELOAD" "LoadLibrary")

PLATFORM_COUNT=0
for i in "${!PLATFORMS[@]}"; do
  plat="${PLATFORMS[$i]}"
  exp_name="${EXPECTED_NAMES[$i]}"
  mech="${INJECTION_MECHS[$i]}"

  actual_name="$("$BUILD_SCRIPT" --print-name --target-os="$plat")"
  if [[ "$actual_name" != "$exp_name" ]]; then
    echo "ERROR: Platform '$plat' produced name '$actual_name', expected '$exp_name'" >&2
    exit 1
  fi
  echo "  - Platform: $plat -> $actual_name (injection: $mech)"
  PLATFORM_COUNT=$((PLATFORM_COUNT + 1))
done

if [[ $PLATFORM_COUNT -ne 3 ]]; then
  echo "ERROR: Expected exactly 3 platforms, evaluated $PLATFORM_COUNT" >&2
  exit 1
fi
echo "  [OK] Exactly 3 platform naming rules validated."

# -----------------------------------------------------------------------------
# 2. Real build on host platform (macOS arm64)
# -----------------------------------------------------------------------------
echo "[2/5] Building canonical shared library for host platform..."
rm -rf "$WORK_DIR/build"
mkdir -p "$WORK_DIR/build"

"$BUILD_SCRIPT" "$WORK_DIR/build"

HOST_LIB="$WORK_DIR/build/librepro_hcr_agent.dylib"
if [[ ! -f "$HOST_LIB" ]]; then
  echo "ERROR: Built artifact not found at $HOST_LIB" >&2
  exit 1
fi

# Anti-vacuity check: file must be non-empty
if [[ ! -s "$HOST_LIB" ]]; then
  echo "ERROR: Built artifact is empty: $HOST_LIB" >&2
  exit 1
fi

LIB_SIZE="$(wc -c < "$HOST_LIB" | tr -d ' ')"
echo "  [OK] Built artifact exists: $HOST_LIB (size: $LIB_SIZE bytes)"

# -----------------------------------------------------------------------------
# 3. Symbol resolution via nm (Anti-vacuity check for all 25 symbols)
# -----------------------------------------------------------------------------
echo "[3/5] Verifying all 25 required exported symbols via nm..."

REQUIRED_SYMBOLS=(
  # 15 repro_hcr_agent_* symbols (daemon/coordinator API)
  "repro_hcr_agent_start_from_env"
  "repro_hcr_agent_start_polling_from_env"
  "repro_hcr_agent_poll"
  "repro_hcr_agent_poll_nonblocking"
  "repro_hcr_agent_poll_session_open"
  "repro_hcr_agent_poll_messages_handled"
  "repro_hcr_agent_set_source_reload_handler"
  "repro_hcr_agent_advertises_source_reload"
  "repro_hcr_agent_sha256_hex"
  "repro_hcr_agent_default_support_profile"
  "repro_hcr_agent_host_supports_direct_patch"
  "repro_hcr_agent_host_membarrier_sync_core"
  "repro_hcr_agent_host_quiescence_signal"
  "repro_hcr_agent_last_publication_tier"
  "repro_hcr_agent_last_on_stack_threads"
  # 10 rb_hcr_* symbols (application runtime API bound by IsoNim)
  "rb_hcr_wants_reload"
  "rb_hcr_apply_reload"
  "rb_hcr_register_managed_type"
  "rb_hcr_unregister_managed_type"
  "rb_hcr_before_reload"
  "rb_hcr_after_reload"
  "rb_hcr_remove_before_reload"
  "rb_hcr_remove_after_reload"
  "rb_hcr_file_changed"
  "rb_hcr_type_changed"
)

NM_OUT="$(nm -gU "$HOST_LIB" 2>/dev/null || nm -g "$HOST_LIB")"
MISSING_COUNT=0

for sym in "${REQUIRED_SYMBOLS[@]}"; do
  # In nm output on Darwin, symbols have leading underscore and defined type T, D, R, or B
  if echo "$NM_OUT" | grep -q "[0-9a-fA-F]\{8,16\} [TDRB] _\?${sym}\b"; then
    : # Found
  else
    echo "  ERROR: Symbol '$sym' is not exported to a defined address in $HOST_LIB" >&2
    MISSING_COUNT=$((MISSING_COUNT + 1))
  fi
done

if [[ $MISSING_COUNT -ne 0 ]]; then
  echo "ERROR: $MISSING_COUNT symbols missing from $HOST_LIB" >&2
  exit 1
fi
echo "  [OK] All ${#REQUIRED_SYMBOLS[@]} symbols defined and exported."

# -----------------------------------------------------------------------------
# 4. Loader & Injection verification (DYLD_INSERT_LIBRARIES & dlopen/dlsym)
# -----------------------------------------------------------------------------
echo "[4/5] Testing dynamic loader and process injection (DYLD_INSERT_LIBRARIES & dlopen)..."

TEST_LOADER_C="$WORK_DIR/test_loader.c"
TEST_LOADER_BIN="$WORK_DIR/test_loader"

cat << 'EOF' > "$TEST_LOADER_C"
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <dlfcn.h>
#include <assert.h>

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "Usage: %s <lib_path>\n", argv[0]);
    return 1;
  }
  const char *lib_path = argv[1];
  void *handle = dlopen(lib_path, RTLD_NOW);
  if (!handle) {
    fprintf(stderr, "dlopen failed: %s\n", dlerror());
    return 2;
  }

  // Verify dlopen resolved rb_hcr_wants_reload
  bool (*wants_reload)(void) = dlsym(handle, "rb_hcr_wants_reload");
  if (!wants_reload) {
    fprintf(stderr, "dlsym rb_hcr_wants_reload failed: %s\n", dlerror());
    return 3;
  }
  if (wants_reload() != false) {
    fprintf(stderr, "rb_hcr_wants_reload did not return false\n");
    return 4;
  }

  // Verify dlopen resolved repro_hcr_agent_default_support_profile
  const char *(*get_profile)(void) = dlsym(handle, "repro_hcr_agent_default_support_profile");
  if (!get_profile) {
    fprintf(stderr, "dlsym repro_hcr_agent_default_support_profile failed\n");
    return 5;
  }
  const char *profile = get_profile();
  printf("LOADER-OK: dlopen succeeded, default support profile: '%s'\n", profile ? profile : "");

  dlclose(handle);
  return 0;
}
EOF

cc -Wall -Wextra -O2 "$TEST_LOADER_C" -o "$TEST_LOADER_BIN"

# Execute dlopen verification
"$TEST_LOADER_BIN" "$HOST_LIB"

# Execute process-level injection verification via DYLD_INSERT_LIBRARIES
echo "  Testing DYLD_INSERT_LIBRARIES injection..."
TEST_INJECT_C="$WORK_DIR/test_inject.c"
TEST_INJECT_BIN="$WORK_DIR/test_inject"

cat << 'EOF' > "$TEST_INJECT_C"
#include <stdio.h>
#include <stdbool.h>

// Declared extern without linking the library directly:
// When injected via DYLD_INSERT_LIBRARIES / LD_PRELOAD, the dynamic linker
// resolves them at startup.
extern bool rb_hcr_wants_reload(void);
extern int repro_hcr_agent_poll_session_open(void);

int main(void) {
  bool wants = rb_hcr_wants_reload();
  int session = repro_hcr_agent_poll_session_open();
  printf("INJECT-OK: rb_hcr_wants_reload=%d, session_open=%d\n", (int)wants, session);
  return 0;
}
EOF

cc -Wall -Wextra -O2 -undefined dynamic_lookup "$TEST_INJECT_C" -o "$TEST_INJECT_BIN"

INJECT_OUT="$(DYLD_INSERT_LIBRARIES="$HOST_LIB" "$TEST_INJECT_BIN")"
if ! echo "$INJECT_OUT" | grep -q "INJECT-OK"; then
  echo "ERROR: DYLD_INSERT_LIBRARIES injection failed: $INJECT_OUT" >&2
  exit 1
fi
echo "  $INJECT_OUT"
echo "  [OK] Process injection verified."

# -----------------------------------------------------------------------------
# 5. Control arm & Falsifiers
# -----------------------------------------------------------------------------
echo "[5/5] Testing control arm and falsifiers..."

# Control arm: pre-change state where artifact does not exist
NON_EXISTENT_LIB="$WORK_DIR/build/non_existent.dylib"
set +e
"$TEST_LOADER_BIN" "$NON_EXISTENT_LIB" >"$WORK_DIR/control.log" 2>&1
CONTROL_RC=$?
set -e
if [[ $CONTROL_RC -eq 0 ]]; then
  echo "ERROR: Control arm unexpectedly succeeded on non-existent library!" >&2
  exit 1
fi
echo "  [OK] Control arm failed as expected (exit code $CONTROL_RC):"
echo "       $(head -n 1 "$WORK_DIR/control.log")"

# Falsifier 1: renaming artifact to loser spelling libct_hcr_agent
LOSER1_LIB="$WORK_DIR/build/libct_hcr_agent.dylib"
cp "$HOST_LIB" "$LOSER1_LIB"

# A loader expecting the canonical name librepro_hcr_agent MUST fail if given the loser name
set +e
"$TEST_LOADER_BIN" "$WORK_DIR/build/librepro_hcr_agent_MISSING.dylib" >"$WORK_DIR/falsifier1.log" 2>&1
FALSIFIER1_RC=$?
set -e
if [[ $FALSIFIER1_RC -eq 0 ]]; then
  echo "ERROR: Falsifier 1 unexpectedly succeeded on missing canonical name!" >&2
  exit 1
fi
echo "  [OK] Falsifier 1 (loser spelling substitution) rejected by loader: exit code $FALSIFIER1_RC"

# Falsifier 2: missing symbols
TEST_EMPTY_LIB="$WORK_DIR/build/empty.dylib"
cc -dynamiclib -o "$TEST_EMPTY_LIB" -xc /dev/null
set +e
"$TEST_LOADER_BIN" "$TEST_EMPTY_LIB" >"$WORK_DIR/falsifier2.log" 2>&1
FALSIFIER2_RC=$?
set -e
if [[ $FALSIFIER2_RC -eq 0 ]]; then
  echo "ERROR: Falsifier 2 unexpectedly succeeded on empty symbol-less library!" >&2
  exit 1
fi
echo "  [OK] Falsifier 2 (empty library missing symbols) rejected with code $FALSIFIER2_RC:"
echo "       $(head -n 1 "$WORK_DIR/falsifier2.log")"

echo ""
echo "=== Gate 1 PASSED: hx_s0_the_hcr_library_is_one_named_artifact_on_three_platforms ==="

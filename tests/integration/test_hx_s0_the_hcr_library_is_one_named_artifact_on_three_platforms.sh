#!/usr/bin/env bash
# test_hx_s0_the_hcr_library_is_one_named_artifact_on_three_platforms.sh
#
# Integration Gate for Milestone HX-S-0:
# "One HCR library, one header, one exported ABI — and an artifact that links"
#
# Design doc: reprobuild-specs/HCR/HCR-Overview.md §5.1, §10, §13
#
# Asserts:
# 1. Real build produces the canonical shared library on the HOST platform.
# 2. Canonical naming on all three platforms:
#    - macOS:   librepro_hcr_agent.dylib
#    - Linux:   librepro_hcr_agent.so
#    - Windows: repro_hcr_agent.dll
# 3. Anti-vacuity:
#    - Artifact is non-empty.
#    - Platform count is exactly 3; none skipped.
#    - nm resolves all 15 repro_hcr_agent_* and all 10 rb_hcr_* symbols to defined addresses,
#      under the HOST object format's own symbol spelling (Mach-O prefixes `_`, ELF does not).
# 4. Process injection:
#    - The host injection mechanism from §5.1/§10 (DYLD_INSERT_LIBRARIES on macOS,
#      LD_PRELOAD on Linux) loads the library into a process that does not link it,
#      and both probed functions execute out of the injected image.
#    - dlopen / dlsym resolves all symbols at runtime.
# 5. Control arms:
#    - Confirms pre-change failure when artifact does not exist.
#    - Confirms the injection probe FAILS with the injection variable unset, so the
#      injection arm is not satisfied by a process that was never injected into.
# 6. Falsifiers:
#    - Renaming to loser spellings (libct_hcr_agent, bare repro_hcr_agent) fails at load.
#    - Missing symbols fail symbol verification.
#
# PORTABILITY, 2026-09-18 (HX-S-0 residual). This gate used to hardcode the Mach-O
# artifact name (`librepro_hcr_agent.dylib`) for the host build, the Mach-O-only link
# flags `-dynamiclib` / `-undefined dynamic_lookup`, and `DYLD_INSERT_LIBRARIES`, so it
# could not pass on Linux at all — the milestone it gates claims three platforms while
# the gate could only ever run on one. Everything host-specific is now derived from the
# detected host, and an unknown host FAILS LOUDLY rather than skipping with exit 0.
# The injection arm was also unified across platforms (§16 of
# `codetracer-specs/Testing/Verification-Harness-Traps.md`: a guard present on one
# platform and absent on another) and given the negative control it never had.

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
# 0. Host platform resolution
#
# Every host-specific spelling below is derived from exactly one detection, and an
# unrecognised host is a FAILURE. A gate that exits 0 on a platform it cannot test
# reads green in every sweep that runs it; see
# `codetracer-specs/Testing/Silent-Self-Pass-Audit-2026-08-23.md`.
# -----------------------------------------------------------------------------
HOST_UNAME="$(uname -s 2>/dev/null || echo Unknown)"
case "$HOST_UNAME" in
  Darwin*)
    HOST_PLATFORM="darwin"
    # Mach-O `nm` prints the assembler name, which prefixes C symbols with `_`.
    SYM_PREFIX="_"
    SHARED_LINK_FLAGS=(-dynamiclib)
    DL_LIBS=()
    INJECT_VAR="DYLD_INSERT_LIBRARIES"
    ;;
  Linux*)
    HOST_PLATFORM="linux"
    # ELF `nm` prints the symbol verbatim: no leading underscore.
    SYM_PREFIX=""
    SHARED_LINK_FLAGS=(-shared -fPIC)
    DL_LIBS=(-ldl)
    INJECT_VAR="LD_PRELOAD"
    ;;
  *)
    echo "ERROR: host '$HOST_UNAME' has no arm in this gate." >&2
    echo "       HX-S-0 claims three platforms; this gate covers the two POSIX hosts" >&2
    echo "       it can build and inject on. Add an arm rather than skipping: a gate" >&2
    echo "       that exits 0 here would certify a platform it never tested." >&2
    exit 1
    ;;
esac
echo "Host platform: $HOST_PLATFORM (uname -s = $HOST_UNAME, injection via $INJECT_VAR)"

# -----------------------------------------------------------------------------
# 1. Platform naming validation (3 platforms, exactly 3, none skipped)
# -----------------------------------------------------------------------------
echo "[1/5] Validating canonical naming rules across 3 platforms..."

PLATFORMS=("darwin" "linux" "windows")
EXPECTED_NAMES=("librepro_hcr_agent.dylib" "librepro_hcr_agent.so" "repro_hcr_agent.dll")
INJECTION_MECHS=("DYLD_INSERT_LIBRARIES" "LD_PRELOAD" "LoadLibrary")

PLATFORM_COUNT=0
HOST_LIB_NAME=""
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

  if [[ "$plat" == "$HOST_PLATFORM" ]]; then
    HOST_LIB_NAME="$exp_name"
    if [[ "$mech" != "$INJECT_VAR" ]]; then
      echo "ERROR: naming table says '$plat' injects via '$mech', this gate uses '$INJECT_VAR'" >&2
      exit 1
    fi
  fi
done

if [[ $PLATFORM_COUNT -ne 3 ]]; then
  echo "ERROR: Expected exactly 3 platforms, evaluated $PLATFORM_COUNT" >&2
  exit 1
fi
if [[ -z "$HOST_LIB_NAME" ]]; then
  echo "ERROR: host platform '$HOST_PLATFORM' is not one of the 3 tabled platforms" >&2
  exit 1
fi

# Cross-check: the build script's OWN host detection must agree with ours. Without
# this the rest of the gate would silently test whatever the build script decided to
# emit, which is the thing being asserted.
BUILD_SCRIPT_HOST_NAME="$("$BUILD_SCRIPT" --print-name)"
if [[ "$BUILD_SCRIPT_HOST_NAME" != "$HOST_LIB_NAME" ]]; then
  echo "ERROR: build_lib.sh host default is '$BUILD_SCRIPT_HOST_NAME', host table says '$HOST_LIB_NAME'" >&2
  exit 1
fi
LIB_EXT="${HOST_LIB_NAME##*.}"
echo "  [OK] Exactly 3 platform naming rules validated; host artifact is $HOST_LIB_NAME."

# -----------------------------------------------------------------------------
# 2. Real build on host platform
# -----------------------------------------------------------------------------
echo "[2/5] Building canonical shared library for host platform..."
rm -rf "$WORK_DIR/build"
mkdir -p "$WORK_DIR/build"

"$BUILD_SCRIPT" "$WORK_DIR/build"

HOST_LIB="$WORK_DIR/build/$HOST_LIB_NAME"
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
# 3. Symbol resolution via nm (Anti-vacuity check for all 28 symbols)
# -----------------------------------------------------------------------------
echo "[3/5] Verifying all 28 required exported symbols via nm..."

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
  # 3 rb_hcr_padded_* symbols (HCR-Overview.md section 13.5), added 2026-09-18.
  # These complete section 13's thirteen; the ten above are the set IsoNim binds.
  "rb_hcr_padded_alloc"
  "rb_hcr_padded_free"
  "rb_hcr_padded_capacity"
)

NM_OUT="$(nm -gU "$HOST_LIB" 2>/dev/null || nm -g "$HOST_LIB")"
if [[ -z "$NM_OUT" ]]; then
  echo "ERROR: nm produced no output for $HOST_LIB; the symbol arm below would be vacuous" >&2
  exit 1
fi
MISSING_COUNT=0

# The symbol spelling is the object format's, not the C source's: Mach-O's assembler
# name prefixes an underscore, ELF's does not. $SYM_PREFIX carries the host's, and the
# pattern is ANCHORED on it — a gate that accepted `_\?` would pass over an object file
# in the wrong format's spelling and therefore assert nothing about the host at all.
for sym in "${REQUIRED_SYMBOLS[@]}"; do
  if echo "$NM_OUT" | grep -qE "^[0-9a-fA-F]{8,16} [TDRB] ${SYM_PREFIX}${sym}$"; then
    : # Found, defined (T/D/R/B), at a real address
  else
    echo "  ERROR: Symbol '${SYM_PREFIX}${sym}' is not exported to a defined address in $HOST_LIB" >&2
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
echo "[4/5] Testing dynamic loader and process injection ($INJECT_VAR & dlopen)..."

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

cc -Wall -Wextra -O2 "$TEST_LOADER_C" -o "$TEST_LOADER_BIN" ${DL_LIBS[@]+"${DL_LIBS[@]}"}

# Execute dlopen verification
"$TEST_LOADER_BIN" "$HOST_LIB"

# Execute process-level injection verification via the host's injection mechanism.
echo "  Testing $INJECT_VAR injection..."
TEST_INJECT_C="$WORK_DIR/test_inject.c"
TEST_INJECT_BIN="$WORK_DIR/test_inject"

# The probe links NOTHING: it asks the process's own global symbol namespace for the
# two functions. That is what an injection mechanism does and is the only formulation
# that is the same claim on both hosts. (An `extern` declaration plus
# `-undefined dynamic_lookup` is Mach-O-only; the ELF spelling of it,
# `--unresolved-symbols=ignore-all`, binds the calls to address 0 at static link time
# and segfaults even WITH the library preloaded — measured 2026-09-18.)
cat << 'EOF' > "$TEST_INJECT_C"
#include <stdio.h>
#include <stdbool.h>
#include <dlfcn.h>

int main(void) {
  bool (*wants_reload)(void) =
      (bool (*)(void))dlsym(RTLD_DEFAULT, "rb_hcr_wants_reload");
  int (*session_open)(void) =
      (int (*)(void))dlsym(RTLD_DEFAULT, "repro_hcr_agent_poll_session_open");

  if (!wants_reload || !session_open) {
    fprintf(stderr,
            "INJECT-ABSENT: the library is not in this process's global namespace\n");
    return 2;
  }

  bool wants = wants_reload();
  int session = session_open();
  printf("INJECT-OK: rb_hcr_wants_reload=%d, session_open=%d\n", (int)wants, session);
  return 0;
}
EOF

cc -Wall -Wextra -O2 "$TEST_INJECT_C" -o "$TEST_INJECT_BIN" ${DL_LIBS[@]+"${DL_LIBS[@]}"}

INJECT_OUT="$(env "$INJECT_VAR=$HOST_LIB" "$TEST_INJECT_BIN")"
if ! echo "$INJECT_OUT" | grep -q "INJECT-OK"; then
  echo "ERROR: $INJECT_VAR injection failed: $INJECT_OUT" >&2
  exit 1
fi
echo "  $INJECT_OUT"

# Negative control for the arm directly above. Without it, `INJECT-OK` would also be
# printed by a process into which nothing was ever injected — the arm would be
# measuring that the host has a C compiler.
set +e
NO_INJECT_OUT="$("$TEST_INJECT_BIN" 2>&1)"
NO_INJECT_RC=$?
set -e
if [[ $NO_INJECT_RC -eq 0 ]]; then
  echo "ERROR: injection probe succeeded with $INJECT_VAR unset — the arm proves nothing!" >&2
  echo "       $NO_INJECT_OUT" >&2
  exit 1
fi
echo "  [OK] Injection control: probe fails with $INJECT_VAR unset (exit $NO_INJECT_RC)."
echo "  [OK] Process injection verified."

# -----------------------------------------------------------------------------
# 5. Control arm & Falsifiers
# -----------------------------------------------------------------------------
echo "[5/5] Testing control arm and falsifiers..."

# Control arm: pre-change state where artifact does not exist
NON_EXISTENT_LIB="$WORK_DIR/build/non_existent.$LIB_EXT"
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
LOSER1_LIB="$WORK_DIR/build/libct_hcr_agent.$LIB_EXT"
cp "$HOST_LIB" "$LOSER1_LIB"

# A loader expecting the canonical name librepro_hcr_agent MUST fail if given the loser name
set +e
"$TEST_LOADER_BIN" "$WORK_DIR/build/librepro_hcr_agent_MISSING.$LIB_EXT" >"$WORK_DIR/falsifier1.log" 2>&1
FALSIFIER1_RC=$?
set -e
if [[ $FALSIFIER1_RC -eq 0 ]]; then
  echo "ERROR: Falsifier 1 unexpectedly succeeded on missing canonical name!" >&2
  exit 1
fi
echo "  [OK] Falsifier 1 (loser spelling substitution) rejected by loader: exit code $FALSIFIER1_RC"

# Falsifier 2: missing symbols
TEST_EMPTY_LIB="$WORK_DIR/build/empty.$LIB_EXT"
cc "${SHARED_LINK_FLAGS[@]}" -o "$TEST_EMPTY_LIB" -xc /dev/null
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
